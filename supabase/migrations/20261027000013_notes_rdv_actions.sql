-- Lot 3B (cahier des charges du 27/10/2026) : notes signées, cycle du rendez-vous, prochaines actions.
-- Ajouts uniquement : aucune ligne n'est supprimée.

alter table public.requests
  add column rdv_status text check (rdv_status in ('a_dater','planifie','confirme','realise','annule','absent'));
alter table public.tasks add column all_day boolean not null default false;  -- échéance sans heure

-- Reprise : un RDV du classeur sans date est « à dater », avec date « planifié ». Rien n'est déduit de plus.
update public.requests set rdv_status = case when rdv_on is null then 'a_dater' else 'planifie' end
  where rdv_origin = 'import' or stage = 'rdv_pris';

-- Note libre : datée, signée par son auteur. Ne vaut ni appel ni changement d'étape.
create function public.add_note(p_request bigint, p_text text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.can_act(p_request) then raise exception 'FORBIDDEN'; end if;
  if coalesce(btrim(p_text), '') = '' or length(btrim(p_text)) < 2 then raise exception 'NOTE_REQUIRED'; end if;
  if length(p_text) > 2000 then raise exception 'NOTE_TOO_LONG'; end if;
  insert into public.activities (request_id, type, author, note, data)
    values (p_request, 'note', auth.uid(), btrim(p_text), jsonb_build_object('kind', 'free'));
end $$;

-- Changement de qualité : journalisé dans la chronologie avec l'ancienne et la nouvelle valeur.
create or replace function public.set_quality(p_request bigint, p_quality public.request_quality)
returns void language plpgsql security definer set search_path = '' as $$
declare old public.request_quality;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  select quality into old from public.requests where id = p_request for update;
  update public.requests set quality = p_quality, version = version + 1, updated_at = now() where id = p_request;
  if p_quality in ('doublon','spam') then
    perform public.cancel_open_tasks(p_request, array['mail','callback','call']::public.task_kind[]);
  end if;
  if old is distinct from p_quality then
    insert into public.activities (request_id, type, author, data)
      values (p_request, 'note', auth.uid(), jsonb_build_object('kind', 'change', 'field', 'quality', 'old', old, 'new', p_quality));
  end if;
  insert into public.audit_log (actor, action, entity, entity_id, details)
    values (auth.uid(), 'set_quality', 'requests', p_request::text, jsonb_build_object('quality', p_quality, 'old', old));
end $$;

-- Un RDV pris ou reporté est « planifié » ; l'ancienne date reste dans la chronologie (une ligne par prise de RDV).
create or replace function public.book_appointment(p_request bigint, p_date date, p_time time default null,
  p_time_tbd boolean default false, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_date is null or (p_time is null and not p_time_tbd) then raise exception 'DATE_AND_TIME_REQUIRED'; end if;
  perform public.lock_request(p_request);
  insert into public.activities (request_id, type, author, note, data)
    values (p_request, 'appointment', auth.uid(), p_note, jsonb_build_object('date', p_date, 'time', p_time, 'tbd', p_time_tbd));
  update public.requests set rdv_on=p_date, rdv_time=p_time, rdv_time_tbd=p_time_tbd, rdv_origin='confirme', rdv_status='planifie',
    version=version+1, updated_at=now(),
    stage = case when stage in ('recu','a_contacter','contact_etabli') then 'rdv_pris' else stage end
    where id = p_request;
  perform public.cancel_open_tasks(p_request, array['call','callback','mail']::public.task_kind[]);
end $$;

-- Cycle du rendez-vous. Annulé ou absent : une suite (rappel) est obligatoire ; l'historique est conservé.
create function public.set_rdv_status(p_request bigint, p_status text, p_note text default null, p_due timestamptz default null)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.requests;
begin
  if p_status not in ('confirme','realise','annule','absent') then raise exception 'BAD_STATUS'; end if;
  r := public.lock_request(p_request);
  if r.rdv_on is null and r.stage <> 'rdv_pris' then raise exception 'NO_APPOINTMENT'; end if;
  if p_status in ('annule','absent') and p_due is null then raise exception 'NEXT_ACTION_REQUIRED'; end if;
  insert into public.activities (request_id, type, author, note, data)
    values (p_request, 'note', auth.uid(), p_note, jsonb_build_object('kind', 'rdv_status', 'status', p_status, 'old', r.rdv_status, 'rdv_on', r.rdv_on));
  update public.requests set rdv_status = p_status, version = version + 1, updated_at = now(),
    stage = case when p_status in ('annule','absent') and stage = 'rdv_pris' then 'contact_etabli' else stage end
    where id = p_request;
  if p_status in ('annule','absent') then
    perform public.cancel_open_tasks(p_request, array['call','callback']::public.task_kind[]);
    insert into public.tasks (request_id, kind, due_at, created_by) values (p_request, 'callback', p_due, auth.uid());
    update public.requests set last_result = 'a_rappeler', next_action = 'rappeler'::public.next_action, next_action_due = p_due where id = p_request;
  end if;
end $$;

-- Rappel sur une journée sans heure : le retard commence le jour suivant (heure de Paris).
create function public.schedule_callback_day(p_request bigint, p_date date, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare due timestamptz;
begin
  if p_date is null then raise exception 'DUE_REQUIRED'; end if;
  perform public.lock_request(p_request);
  due := ((p_date + 1)::timestamp) at time zone 'Europe/Paris';
  insert into public.activities (request_id, type, author, note, data)
    values (p_request, 'callback', auth.uid(), p_note, jsonb_build_object('due', due, 'day', p_date, 'all_day', true));
  perform public.cancel_open_tasks(p_request, array['call','callback']::public.task_kind[]);
  insert into public.tasks (request_id, kind, due_at, all_day, created_by) values (p_request, 'callback', due, true, auth.uid());
  update public.requests set last_result = 'a_rappeler', next_action = 'rappeler'::public.next_action, next_action_due = due,
    version = version + 1, updated_at = now() where id = p_request;
end $$;

-- Terminer ou reprogrammer une prochaine action : toujours explicite et tracé.
create function public.complete_task(p_task bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.tasks;
begin
  select * into t from public.tasks where id = p_task for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public.can_act(t.request_id) then raise exception 'FORBIDDEN'; end if;
  if t.status <> 'open' then raise exception 'TASK_NOT_OPEN'; end if;
  update public.tasks set status = 'done' where id = p_task;
  insert into public.activities (request_id, type, author, data)
    values (t.request_id, 'note', auth.uid(), jsonb_build_object('kind', 'task_done', 'task_kind', t.kind, 'due', t.due_at));
  if not exists (select 1 from public.tasks where request_id = t.request_id and status = 'open') then
    update public.requests set next_action = null, next_action_due = null, version = version + 1, updated_at = now() where id = t.request_id;
  end if;
end $$;

create function public.reschedule_task(p_task bigint, p_due timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.tasks;
begin
  if p_due is null then raise exception 'DUE_REQUIRED'; end if;
  select * into t from public.tasks where id = p_task for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public.can_act(t.request_id) then raise exception 'FORBIDDEN'; end if;
  if t.status <> 'open' then raise exception 'TASK_NOT_OPEN'; end if;
  update public.tasks set due_at = p_due, all_day = false where id = p_task;
  insert into public.activities (request_id, type, author, data)
    values (t.request_id, 'note', auth.uid(), jsonb_build_object('kind', 'task_resched', 'task_kind', t.kind, 'old', t.due_at, 'new', p_due));
  update public.requests set next_action_due = p_due, version = version + 1, updated_at = now() where id = t.request_id;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.add_note, public.set_quality, public.book_appointment, public.set_rdv_status,
  public.schedule_callback_day, public.complete_task, public.reschedule_task to authenticated;
