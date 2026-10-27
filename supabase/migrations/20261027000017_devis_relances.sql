-- Cahier des charges 27/10/2026, RAP01 : relance de devis, absence de suite justifiée, annulation d'une action.
-- Ajouts uniquement.
alter table public.requests add column no_next_reason text;  -- justification d'une absence volontaire de prochaine action

create function public.set_no_next_action(p_request bigint, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.can_act(p_request) then raise exception 'FORBIDDEN'; end if;
  update public.requests set no_next_reason = nullif(btrim(p_reason), ''), version = version + 1, updated_at = now() where id = p_request;
  insert into public.activities (request_id, type, author, note, data)
    values (p_request, 'note', auth.uid(), nullif(btrim(p_reason), ''), jsonb_build_object('kind', 'no_next', 'cleared', coalesce(btrim(p_reason), '') = ''));
end $$;

-- Relance d'un devis : une seule relance ouverte à la fois, avec échéance obligatoire.
create function public.schedule_quote_followup(p_request bigint, p_due timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_due is null then raise exception 'DUE_REQUIRED'; end if;
  perform public.lock_request(p_request);
  perform public.cancel_open_tasks(p_request, array['quote_followup']::public.task_kind[]);
  insert into public.tasks (request_id, kind, due_at, created_by) values (p_request, 'quote_followup', p_due, auth.uid());
  update public.requests set next_action = 'relancer_devis'::public.next_action, next_action_due = p_due, no_next_reason = null,
    version = version + 1, updated_at = now() where id = p_request;
  insert into public.activities (request_id, type, author, data)
    values (p_request, 'note', auth.uid(), jsonb_build_object('kind', 'quote_followup', 'due', p_due));
end $$;

-- Devis réalisé avec référence et relance facultative, en une seule opération.
create function public.record_quote_followup(p_request bigint, p_ref text default null, p_followup timestamptz default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public.record_quote(p_request, p_ref);
  if p_followup is not null then perform public.schedule_quote_followup(p_request, p_followup); end if;
end $$;

-- Annulation d'une prochaine action : motif obligatoire, historique conservé.
create function public.cancel_task(p_task bigint, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.tasks;
begin
  if coalesce(btrim(p_reason), '') = '' then raise exception 'REASON_REQUIRED'; end if;
  select * into t from public.tasks where id = p_task for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public.can_act(t.request_id) then raise exception 'FORBIDDEN'; end if;
  if t.status <> 'open' then raise exception 'TASK_NOT_OPEN'; end if;
  update public.tasks set status = 'cancelled' where id = p_task;
  insert into public.activities (request_id, type, author, note, data)
    values (t.request_id, 'note', auth.uid(), btrim(p_reason), jsonb_build_object('kind', 'task_cancel', 'task_kind', t.kind, 'due', t.due_at));
  if not exists (select 1 from public.tasks where request_id = t.request_id and status = 'open') then
    update public.requests set next_action = null, next_action_due = null, version = version + 1, updated_at = now() where id = t.request_id;
  end if;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.set_no_next_action, public.schedule_quote_followup, public.record_quote_followup, public.cancel_task to authenticated;
