-- Lot 1 (suite) : création de profil pour un compte existant, changement de qualité d'un dossier.
create function public.admin_create_profile(p_email text, p_name text, p_role public.app_role)
returns uuid language plpgsql security definer set search_path = '' as $$
declare u uuid;
begin
  if public.current_role_name() <> 'admin' then raise exception 'FORBIDDEN'; end if;
  select id into u from auth.users where lower(email) = lower(btrim(p_email));
  if u is null then raise exception 'NO_AUTH_ACCOUNT'; end if;
  if coalesce(btrim(p_name),'') = '' then raise exception 'NAME_REQUIRED'; end if;
  insert into public.profiles (id, full_name, role) values (u, btrim(p_name), p_role)
    on conflict (id) do update set full_name = excluded.full_name, role = excluded.role;
  insert into public.audit_log (actor, action, entity, entity_id, details)
    values (auth.uid(), 'create_profile', 'profiles', u::text, jsonb_build_object('role', p_role));
  return u;
end $$;

-- Qualité du dossier : un doublon ou un spam annule les relances mail en attente.
create function public.set_quality(p_request bigint, p_quality public.request_quality)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  update public.requests set quality = p_quality, version = version + 1, updated_at = now() where id = p_request;
  if p_quality in ('doublon','spam') then
    perform public.cancel_open_tasks(p_request, array['mail','callback','call']::public.task_kind[]);
  end if;
  insert into public.audit_log (actor, action, entity, entity_id, details)
    values (auth.uid(), 'set_quality', 'requests', p_request::text, jsonb_build_object('quality', p_quality));
end $$;

revoke execute on function public.admin_create_profile, public.set_quality from public, anon;
grant execute on function public.admin_create_profile, public.set_quality to authenticated;
