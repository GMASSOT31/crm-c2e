-- Lot 2 : activités (appels, rappels, RDV, devis, ventes), tâches, compteurs et relance après 3 appels.
create type public.activity_type as enum
  ('no_answer','contact','callback','appointment','quote','sale','close','reopen','note','mail');
create type public.task_kind as enum ('call','callback','mail','quote','quote_followup');
create type public.task_status as enum ('open','done','cancelled');

alter table public.requests
  add column rdv_on date, add column rdv_time time, add column rdv_time_tbd boolean not null default false,
  add column opt_out boolean not null default false,
  add column close_reason public.contact_result,
  add column sale_on date, add column sale_amount numeric, add column sale_vat text check (sale_vat in ('HT','TTC')),
  add column quote_ref text;

create table public.activities (
  id bigint generated always as identity primary key,
  request_id bigint not null references public.requests(id),
  type public.activity_type not null,
  author uuid references public.profiles(id),
  at timestamptz not null default now(),
  note text,
  data jsonb not null default '{}',
  client_token text unique,           -- neutralise le double clic / la requête répétée
  corrects bigint references public.activities(id)  -- correction : garde la trace de la valeur précédente
);
create index on public.activities (request_id, id);

create table public.tasks (
  id bigint generated always as identity primary key,
  request_id bigint not null references public.requests(id),
  kind public.task_kind not null,
  due_at timestamptz,
  status public.task_status not null default 'open',
  seq_key text unique,                -- une seule tâche mail par séquence d'appels
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create index on public.tasks (request_id, status);

alter table public.activities enable row level security;
alter table public.tasks enable row level security;
create policy act_read on public.activities for select to authenticated
  using (exists (select 1 from public.requests r where r.id = request_id));
create policy task_read on public.tasks for select to authenticated
  using (exists (select 1 from public.requests r where r.id = request_id));
revoke all on public.activities, public.tasks from anon, authenticated;
grant select on public.activities, public.tasks to authenticated;

-- Compteur : appels sans réponse consécutifs depuis le dernier contact établi (+ total historique)
create function public.call_counters(p_request bigint) returns table(consecutive int, total int, seq bigint)
language sql stable security definer set search_path = '' as $$
  with last_c as (select coalesce(max(id),0) id from public.activities where request_id=p_request and type='contact')
  select (select count(*)::int from public.activities a, last_c where a.request_id=p_request and a.type='no_answer' and a.id>last_c.id),
         (select count(*)::int from public.activities where request_id=p_request and type='no_answer'),
         (select id from last_c)
$$;

create function public.can_act(p_request bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.requests r where r.id = p_request and not r.archived and
    (public.is_staff() or (r.assigned_to = auth.uid() and public.current_role_name() = 'commercial')))
$$;

-- Verrou + contrôles communs. Retourne la demande verrouillée.
create function public.lock_request(p_request bigint) returns public.requests
language plpgsql security definer set search_path = '' as $$
declare r public.requests;
begin
  if not public.can_act(p_request) then raise exception 'FORBIDDEN'; end if;
  select * into r from public.requests where id = p_request for update;
  if r.stage in ('cloture_sans_vente') then raise exception 'REQUEST_CLOSED'; end if;
  return r;
end $$;

create function public.cancel_open_tasks(p_request bigint, p_kinds public.task_kind[]) returns void
language sql security definer set search_path = '' as $$
  update public.tasks set status='cancelled'
  where request_id=p_request and status='open' and kind = any(p_kinds)
$$;

-- Appel sans réponse : une validation, un événement, compteur recalculé, tâche mail au 3e appel.
create function public.record_no_answer(p_request bigint, p_note text default null, p_token text default null)
returns table(consecutive int, total int, mail_task_created boolean)
language plpgsql security definer set search_path = '' as $$
declare r public.requests; c record; created boolean := false; n int;
begin
  r := public.lock_request(p_request);
  if p_token is not null and exists (select 1 from public.activities where client_token = p_token) then
    select * into c from public.call_counters(p_request);
    return query select c.consecutive, c.total, false; return;
  end if;
  insert into public.activities (request_id, type, author, note, client_token)
    values (p_request, 'no_answer', auth.uid(), p_note, p_token);
  select * into c from public.call_counters(p_request);
  -- l'étape n'est jamais rétrogradée : un appel sans réponse après devis garde « devis_realise »
  update public.requests set last_result='pas_de_reponse', version=version+1, updated_at=now(),
    stage = case when stage in ('recu') then 'a_contacter' else stage end,
    next_action = case when c.consecutive >= 3 then 'envoyer_mail'::public.next_action else 'rappeler'::public.next_action end
    where id = p_request;
  perform public.cancel_open_tasks(p_request, array['call','callback']::public.task_kind[]);
  if c.consecutive >= 3 then
    insert into public.tasks (request_id, kind, due_at, seq_key, created_by)
      values (p_request, 'mail', now(), p_request || ':' || c.seq, auth.uid())
      on conflict (seq_key) do nothing;
    get diagnostics n = row_count; created := n > 0;
  else
    insert into public.tasks (request_id, kind, due_at, created_by) values (p_request, 'callback', now() + interval '1 day', auth.uid());
  end if;
  return query select c.consecutive, c.total, created;
end $$;

create function public.record_contact(p_request bigint, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.lock_request(p_request);
  insert into public.activities (request_id, type, author, note) values (p_request, 'contact', auth.uid(), p_note);
  update public.requests set last_result=null, version=version+1, updated_at=now(), next_action=null,
    stage = case when stage in ('recu','a_contacter') then 'contact_etabli' else stage end
    where id = p_request;
  -- un contact établi interrompt la séquence et annule la relance mail en attente
  perform public.cancel_open_tasks(p_request, array['call','callback','mail']::public.task_kind[]);
end $$;

create function public.schedule_callback(p_request bigint, p_due timestamptz, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_due is null then raise exception 'DUE_REQUIRED'; end if;
  perform public.lock_request(p_request);
  insert into public.activities (request_id, type, author, note, data)
    values (p_request, 'callback', auth.uid(), p_note, jsonb_build_object('due', p_due));
  perform public.cancel_open_tasks(p_request, array['call','callback']::public.task_kind[]);
  insert into public.tasks (request_id, kind, due_at, created_by) values (p_request, 'callback', p_due, auth.uid());
  update public.requests set last_result='a_rappeler', next_action='rappeler'::public.next_action, next_action_due=p_due,
    version=version+1, updated_at=now() where id = p_request;
end $$;

create function public.book_appointment(p_request bigint, p_date date, p_time time default null,
  p_time_tbd boolean default false, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_date is null or (p_time is null and not p_time_tbd) then raise exception 'DATE_AND_TIME_REQUIRED'; end if;
  perform public.lock_request(p_request);
  insert into public.activities (request_id, type, author, note, data)
    values (p_request, 'appointment', auth.uid(), p_note, jsonb_build_object('date', p_date, 'time', p_time, 'tbd', p_time_tbd));
  update public.requests set rdv_on=p_date, rdv_time=p_time, rdv_time_tbd=p_time_tbd, version=version+1, updated_at=now(),
    stage = case when stage in ('recu','a_contacter','contact_etabli') then 'rdv_pris' else stage end
    where id = p_request;
  perform public.cancel_open_tasks(p_request, array['call','callback','mail']::public.task_kind[]);
end $$;

create function public.record_quote(p_request bigint, p_ref text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.lock_request(p_request);
  insert into public.activities (request_id, type, author, data) values (p_request, 'quote', auth.uid(), jsonb_build_object('ref', p_ref));
  update public.requests set quote_ref=p_ref, version=version+1, updated_at=now(),
    stage = case when stage <> 'vente_faite' then 'devis_realise' else stage end where id = p_request;
end $$;

create function public.record_sale(p_request bigint, p_date date, p_amount numeric default null, p_vat text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_date is null then raise exception 'SALE_DATE_REQUIRED'; end if;
  if p_amount is not null and p_vat is null then raise exception 'VAT_MODE_REQUIRED'; end if;
  perform public.lock_request(p_request);
  insert into public.activities (request_id, type, author, data)
    values (p_request, 'sale', auth.uid(), jsonb_build_object('date', p_date, 'amount', p_amount, 'vat', p_vat));
  update public.requests set stage='vente_faite', sale_on=p_date, sale_amount=p_amount, sale_vat=p_vat,
    next_action=null, version=version+1, updated_at=now() where id = p_request;
  perform public.cancel_open_tasks(p_request, array['call','callback','mail','quote_followup']::public.task_kind[]);
end $$;

-- Clôture : motif obligatoire, relances annulées. Réouverture : administrateur, avec motif.
create function public.close_request(p_request bigint, p_reason public.contact_result, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_reason is null then raise exception 'REASON_REQUIRED'; end if;
  perform public.lock_request(p_request);
  insert into public.activities (request_id, type, author, note, data) values (p_request, 'close', auth.uid(), p_note, jsonb_build_object('reason', p_reason));
  update public.requests set stage='cloture_sans_vente', close_reason=p_reason, last_result=p_reason,
    next_action=null, version=version+1, updated_at=now() where id = p_request;
  perform public.cancel_open_tasks(p_request, array['call','callback','mail','quote','quote_followup']::public.task_kind[]);
end $$;

create function public.reopen_request(p_request bigint, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if public.current_role_name() <> 'admin' then raise exception 'FORBIDDEN'; end if;
  if coalesce(btrim(p_reason),'') = '' then raise exception 'REASON_REQUIRED'; end if;
  update public.requests set stage='a_contacter', close_reason=null, version=version+1, updated_at=now() where id = p_request;
  insert into public.activities (request_id, type, author, note) values (p_request, 'reopen', auth.uid(), p_reason);
end $$;

-- Opposition au contact : bloque et annule toute relance mail
create function public.set_opt_out(p_request bigint, p_value boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  update public.requests set opt_out=p_value, version=version+1 where id=p_request;
  if p_value then perform public.cancel_open_tasks(p_request, array['mail']::public.task_kind[]); end if;
  insert into public.audit_log (actor, action, entity, entity_id, details)
    values (auth.uid(), 'set_opt_out', 'requests', p_request::text, jsonb_build_object('value', p_value));
end $$;

-- Pourquoi la relance mail est bloquée (null = autorisée)
create function public.mail_block_reason(p_request bigint) returns text
language sql stable security definer set search_path = '' as $$
  select case
    when r.stage='cloture_sans_vente' then 'Dossier clôturé'
    when r.quality in ('doublon','spam') then 'Dossier marqué doublon ou spam'
    when r.opt_out then 'Opposition au contact enregistrée'
    when r.stage in ('rdv_pris','devis_a_faire','devis_realise','vente_faite') then 'Un rendez-vous a été pris'
    when c.email_norm is null or c.email_norm !~ '^[^\s@,]+@[^\s@,]+\.[a-z]{2,}$' then 'Email manquant ou à corriger'
    end
  from public.requests r join public.contacts c on c.id=r.contact_id
  where r.id=p_request and public.can_act(p_request)
$$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.call_counters, public.can_act, public.record_no_answer, public.record_contact,
  public.schedule_callback, public.book_appointment, public.record_quote, public.record_sale,
  public.close_request, public.reopen_request, public.set_opt_out, public.mail_block_reason to authenticated;
revoke execute on function public.lock_request, public.cancel_open_tasks from authenticated;
