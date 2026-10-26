-- « Devis à faire » et « RDV pris » comme actions du commercial.
-- Un RDV pris prouve qu'un contact a eu lieu : il interrompt la séquence d'appels sans réponse.
create or replace function public.call_counters(p_request bigint) returns table(consecutive int, total int, seq bigint)
language sql stable security definer set search_path = '' as $$
  with last_c as (select coalesce(max(id),0) id from public.activities
                  where request_id=p_request and type in ('contact','appointment'))
  select (select count(*)::int from public.activities a, last_c where a.request_id=p_request and a.type='no_answer' and a.id>last_c.id),
         (select count(*)::int from public.activities where request_id=p_request and type='no_answer'),
         (select id from last_c)
$$;

-- Marque le dossier « Devis à faire » (jamais de retour en arrière depuis devis réalisé ou vente) et crée la tâche.
create function public.mark_quote_todo(p_request bigint, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.lock_request(p_request);
  insert into public.activities (request_id, type, author, note, data)
    values (p_request, 'note', auth.uid(), p_note, jsonb_build_object('kind', 'quote_todo'));
  update public.requests set version = version + 1, updated_at = now(),
    next_action = 'realiser_devis'::public.next_action,
    stage = case when stage in ('recu','a_contacter','contact_etabli','rdv_pris') then 'devis_a_faire' else stage end
    where id = p_request;
  perform public.cancel_open_tasks(p_request, array['call','callback','mail','quote']::public.task_kind[]);
  insert into public.tasks (request_id, kind, due_at, created_by) values (p_request, 'quote', now(), auth.uid());
end $$;

-- Un devis réalisé clôt la tâche « devis à faire ».
create or replace function public.record_quote(p_request bigint, p_ref text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.lock_request(p_request);
  insert into public.activities (request_id, type, author, data) values (p_request, 'quote', auth.uid(), jsonb_build_object('ref', p_ref));
  update public.requests set quote_ref=p_ref, version=version+1, updated_at=now(), next_action=null,
    stage = case when stage <> 'vente_faite' then 'devis_realise' else stage end where id = p_request;
  perform public.cancel_open_tasks(p_request, array['quote']::public.task_kind[]);
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.mark_quote_todo, public.record_quote to authenticated;
revoke execute on function public.lock_request, public.cancel_open_tasks, public.zone_owner, public.zone_assign_one, public.link_zones_to_profile from authenticated;
revoke execute on function public.set_zones from authenticated;
