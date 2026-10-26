-- Attribution des dossiers de la reprise historique d'après le nom du commercial noté dans le classeur.
-- Ne crée ni appel, ni tâche, ni mail. Les dossiers incomplets sont ignorés (attribution manuelle avec dérogation).
create function public.assign_historical(p_user uuid, p_label text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0; skipped int := 0;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  if not exists (select 1 from public.profiles where id = p_user and active and role = 'commercial') then
    raise exception 'TARGET_NOT_ACTIVE_SALESPERSON';
  end if;
  if coalesce(btrim(p_label),'') = '' then raise exception 'REASON_REQUIRED'; end if;
  for r in
    select rq.id, c.display_name, c.phone_norm, c.email_norm, rq.stage
    from public.requests rq join public.contacts c on c.id = rq.contact_id
    where rq.assigned_to is null and rq.import_batch_id is not null
      and rq.hist_note like '%Commercial (classeur) : ' || p_label || '%'
    for update of rq
  loop
    if (r.phone_norm is null and r.email_norm is null) or r.display_name is null then
      skipped := skipped + 1; continue;
    end if;
    insert into public.assignments (request_id, to_user, by_user, reason)
      values (r.id, p_user, auth.uid(), 'Attribution d''après le classeur : ' || p_label);
    update public.requests set assigned_to = p_user, assigned_at = now(), updated_at = now(), version = version + 1,
      stage = case when stage = 'recu' then 'a_contacter' else stage end
      where id = r.id;
    n := n + 1;
  end loop;
  insert into public.audit_log (actor, action, entity, details)
    values (auth.uid(), 'assign_historical', 'requests', jsonb_build_object('label', p_label, 'to', p_user, 'assigned', n, 'skipped', skipped));
  return jsonb_build_object('assigned', n, 'skipped', skipped);
end $$;
revoke execute on function public.assign_historical from public, anon;
grant execute on function public.assign_historical to authenticated;
