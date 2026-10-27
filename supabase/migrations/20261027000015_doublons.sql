-- Cahier des charges 27/10/2026, QUA02 : comparer les doublons et décider, sans rien supprimer ni fusionner.
-- Ajouts uniquement. Une décision est réversible et laisse les deux dossiers, leurs historiques et leurs liens intacts.

create table public.duplicate_reviews (
  id bigint generated always as identity primary key,
  request_id bigint not null references public.requests(id),
  other_id bigint not null references public.requests(id),
  decision text not null check (decision in ('doublon','distinct')),
  reason text,
  decided_by uuid references public.profiles(id),
  decided_at timestamptz not null default now(),
  undone_at timestamptz,
  undone_by uuid references public.profiles(id),
  check (request_id <> other_id)
);
create unique index duplicate_reviews_active on public.duplicate_reviews (least(request_id, other_id), greatest(request_id, other_id)) where undone_at is null;
alter table public.duplicate_reviews enable row level security;
create policy dup_read on public.duplicate_reviews for select to authenticated using (public.is_staff());
revoke all on public.duplicate_reviews from anon, authenticated;
grant select on public.duplicate_reviews to authenticated;

-- Décision sur une paire. « doublon » : p_request est le doublon de p_other (qualité doublon, lien conservé).
-- « distinct » : on garde les deux, avec une justification obligatoire.
create function public.decide_duplicate(p_request bigint, p_other bigint, p_decision text, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare old public.request_quality;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  if p_decision not in ('doublon','distinct') then raise exception 'BAD_DECISION'; end if;
  if p_request = p_other then raise exception 'BAD_DECISION'; end if;
  if p_decision = 'distinct' and coalesce(btrim(p_reason), '') = '' then raise exception 'REASON_REQUIRED'; end if;
  if not exists (select 1 from public.requests where id = p_request) or not exists (select 1 from public.requests where id = p_other) then
    raise exception 'NOT_FOUND';
  end if;
  if exists (select 1 from public.duplicate_reviews where undone_at is null
      and least(request_id, other_id) = least(p_request, p_other) and greatest(request_id, other_id) = greatest(p_request, p_other)) then
    raise exception 'ALREADY_DECIDED';
  end if;
  insert into public.duplicate_reviews (request_id, other_id, decision, reason, decided_by)
    values (p_request, p_other, p_decision, nullif(btrim(p_reason), ''), auth.uid());
  if p_decision = 'doublon' then
    select quality into old from public.requests where id = p_request for update;
    update public.requests set quality = 'doublon', duplicate_of = p_other, version = version + 1, updated_at = now() where id = p_request;
    perform public.cancel_open_tasks(p_request, array['mail','callback','call']::public.task_kind[]);
    insert into public.activities (request_id, type, author, note, data)
      values (p_request, 'note', auth.uid(), nullif(btrim(p_reason), ''),
        jsonb_build_object('kind', 'change', 'field', 'quality', 'old', old, 'new', 'doublon', 'duplicate_of', p_other));
  else
    insert into public.activities (request_id, type, author, note, data)
      values (p_request, 'note', auth.uid(), btrim(p_reason), jsonb_build_object('kind', 'dup_distinct', 'other', p_other));
  end if;
  insert into public.audit_log (actor, action, entity, entity_id, details)
    values (auth.uid(), 'decide_duplicate', 'requests', p_request::text, jsonb_build_object('other', p_other, 'decision', p_decision));
end $$;

-- Annulation d'une décision : un doublon confirmé redevient « à vérifier » ; la paire redevient candidate.
create function public.undo_duplicate(p_request bigint, p_other bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare rv public.duplicate_reviews;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  select * into rv from public.duplicate_reviews where undone_at is null
    and least(request_id, other_id) = least(p_request, p_other) and greatest(request_id, other_id) = greatest(p_request, p_other) for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.duplicate_reviews set undone_at = now(), undone_by = auth.uid() where id = rv.id;
  if rv.decision = 'doublon' then
    update public.requests set quality = 'a_verifier', duplicate_of = null, version = version + 1, updated_at = now()
      where id = rv.request_id and quality = 'doublon';
    insert into public.activities (request_id, type, author, data)
      values (rv.request_id, 'note', auth.uid(), jsonb_build_object('kind', 'change', 'field', 'quality', 'old', 'doublon', 'new', 'a_verifier'));
  end if;
  insert into public.audit_log (actor, action, entity, entity_id, details)
    values (auth.uid(), 'undo_duplicate', 'requests', rv.request_id::text, jsonb_build_object('other', rv.other_id, 'decision', rv.decision));
end $$;

-- Opposition au contact : plus aucune nouvelle action de prospection (appel, rappel, rendez-vous).
create or replace function public.record_no_answer(p_request bigint, p_note text default null, p_token text default null)
returns table(consecutive int, total int, mail_task_created boolean)
language plpgsql security definer set search_path = '' as $$
declare r public.requests; c record; created boolean := false; n int;
begin
  r := public.lock_request(p_request);
  if r.opt_out then raise exception 'OPT_OUT'; end if;
  if p_token is not null and exists (select 1 from public.activities where client_token = p_token) then
    select * into c from public.call_counters(p_request);
    return query select c.consecutive, c.total, false; return;
  end if;
  insert into public.activities (request_id, type, author, note, client_token)
    values (p_request, 'no_answer', auth.uid(), p_note, p_token);
  select * into c from public.call_counters(p_request);
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

create or replace function public.schedule_callback(p_request bigint, p_due timestamptz, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.requests;
begin
  if p_due is null then raise exception 'DUE_REQUIRED'; end if;
  r := public.lock_request(p_request);
  if r.opt_out then raise exception 'OPT_OUT'; end if;
  insert into public.activities (request_id, type, author, note, data)
    values (p_request, 'callback', auth.uid(), p_note, jsonb_build_object('due', p_due));
  perform public.cancel_open_tasks(p_request, array['call','callback']::public.task_kind[]);
  insert into public.tasks (request_id, kind, due_at, created_by) values (p_request, 'callback', p_due, auth.uid());
  update public.requests set last_result='a_rappeler', next_action='rappeler'::public.next_action, next_action_due=p_due,
    version=version+1, updated_at=now() where id = p_request;
end $$;

create or replace function public.schedule_callback_day(p_request bigint, p_date date, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare due timestamptz; r public.requests;
begin
  if p_date is null then raise exception 'DUE_REQUIRED'; end if;
  r := public.lock_request(p_request);
  if r.opt_out then raise exception 'OPT_OUT'; end if;
  due := ((p_date + 1)::timestamp) at time zone 'Europe/Paris';
  insert into public.activities (request_id, type, author, note, data)
    values (p_request, 'callback', auth.uid(), p_note, jsonb_build_object('due', due, 'day', p_date, 'all_day', true));
  perform public.cancel_open_tasks(p_request, array['call','callback']::public.task_kind[]);
  insert into public.tasks (request_id, kind, due_at, all_day, created_by) values (p_request, 'callback', due, true, auth.uid());
  update public.requests set last_result = 'a_rappeler', next_action = 'rappeler'::public.next_action, next_action_due = due,
    version = version + 1, updated_at = now() where id = p_request;
end $$;

create or replace function public.book_appointment(p_request bigint, p_date date, p_time time default null,
  p_time_tbd boolean default false, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.requests;
begin
  if p_date is null or (p_time is null and not p_time_tbd) then raise exception 'DATE_AND_TIME_REQUIRED'; end if;
  r := public.lock_request(p_request);
  if r.opt_out then raise exception 'OPT_OUT'; end if;
  insert into public.activities (request_id, type, author, note, data)
    values (p_request, 'appointment', auth.uid(), p_note, jsonb_build_object('date', p_date, 'time', p_time, 'tbd', p_time_tbd));
  update public.requests set rdv_on=p_date, rdv_time=p_time, rdv_time_tbd=p_time_tbd, rdv_origin='confirme', rdv_status='planifie',
    version=version+1, updated_at=now(),
    stage = case when stage in ('recu','a_contacter','contact_etabli') then 'rdv_pris' else stage end
    where id = p_request;
  perform public.cancel_open_tasks(p_request, array['call','callback','mail']::public.task_kind[]);
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.decide_duplicate, public.undo_duplicate, public.record_no_answer, public.schedule_callback,
  public.schedule_callback_day, public.book_appointment to authenticated;
