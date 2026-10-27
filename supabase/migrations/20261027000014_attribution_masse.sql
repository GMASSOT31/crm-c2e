-- Lot 4 (cahier des charges du 27/10/2026) : simulation des zones et attribution en masse avec rapport.
-- Ajouts uniquement : aucune donnée n'est modifiée par cette migration.

-- Simulation : même périmètre et même règle que apply_zones(), sans rien écrire.
create function public.simulate_zones() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r record; c public.contacts; u uuid; out jsonb := '[]'::jsonb;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  for r in select id, contact_id from public.requests where assigned_to is null and not archived
      and quality not in ('doublon','spam') and stage not in ('cloture_sans_vente','vente_faite') order by id loop
    select * into c from public.contacts where id = r.contact_id;
    if (c.phone_norm is null and c.email_norm is null) or c.display_name is null then
      out := out || jsonb_build_array(jsonb_build_object('id', r.id, 'status', 'incomplet'));
    else
      u := public.zone_owner(c.postal_code, c.address, c.city);
      out := out || jsonb_build_array(jsonb_build_object('id', r.id, 'status', case when u is null then 'non_couvert' else 'ok' end, 'owner', u));
    end if;
  end loop;
  return out;
end $$;

-- Attribution en masse : chaque dossier est traité séparément, les échecs sont rendus avec leur motif.
-- Un dossier déjà attribué à un commercial actif n'est jamais repris (protège des traitements concurrents).
create function public.assign_requests_report(p_request_ids bigint[], p_to uuid,
  p_reason text default null, p_override_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare rid bigint; rq public.requests; ct public.contacts; ok int := 0; same int := 0; failed jsonb := '[]'::jsonb;
  incomplete boolean; why text;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  if not exists (select 1 from public.profiles where id = p_to and active and role = 'commercial') then
    raise exception 'TARGET_NOT_ACTIVE_SALESPERSON';
  end if;
  if coalesce(array_length(p_request_ids, 1), 0) > 1000 then raise exception 'TOO_MANY'; end if;
  if p_override_reason is not null and public.current_role_name() <> 'admin' then raise exception 'FORBIDDEN'; end if;
  foreach rid in array (select coalesce(array_agg(distinct x), '{}') from unnest(p_request_ids) x) loop
    why := null;
    select * into rq from public.requests where id = rid for update;
    if not found then why := 'INTROUVABLE';
    elsif rq.archived or rq.stage in ('cloture_sans_vente','vente_faite') then why := 'CLOTURE';
    elsif rq.quality in ('doublon','spam') then why := 'DOUBLON_SPAM';
    elsif rq.opt_out then why := 'OPPOSITION';
    elsif rq.assigned_to is not distinct from p_to then same := same + 1; continue;
    elsif rq.assigned_to is not null and exists (select 1 from public.profiles where id = rq.assigned_to and active) then why := 'DEJA_ATTRIBUE';
    else
      select * into ct from public.contacts where id = rq.contact_id;
      incomplete := (ct.phone_norm is null and ct.email_norm is null) or ct.display_name is null;
      if incomplete and coalesce(btrim(p_override_reason), '') = '' then why := 'INCOMPLET'; end if;
    end if;
    if why is not null then
      failed := failed || jsonb_build_array(jsonb_build_object('id', rid, 'reason', why));
      continue;
    end if;
    insert into public.assignments (request_id, from_user, to_user, by_user, reason, override_reason)
      values (rid, rq.assigned_to, p_to, auth.uid(), p_reason, case when incomplete then p_override_reason end);
    update public.requests set assigned_to = p_to, assigned_at = now(), updated_at = now(), version = version + 1,
      stage = case when stage = 'recu' then 'a_contacter' else stage end,
      next_action = coalesce(next_action, 'appeler') where id = rid;
    ok := ok + 1;
  end loop;
  insert into public.audit_log (actor, action, entity, details)
    values (auth.uid(), 'assign_requests_report', 'requests',
      jsonb_build_object('to', p_to, 'assigned', ok, 'already', same, 'failed', jsonb_array_length(failed), 'override', p_override_reason is not null));
  return jsonb_build_object('assigned', ok, 'already', same, 'failed', failed);
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.simulate_zones, public.assign_requests_report to authenticated;
