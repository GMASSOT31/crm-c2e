-- Attribution automatique par zone : code postal (préfixe) ou ville -> commercial.
create table public.assignment_zones (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id),
  kind text not null check (kind in ('postal','city')),
  value text not null,
  unique (kind, value)
);
alter table public.assignment_zones enable row level security;
create policy zones_read on public.assignment_zones for select to authenticated using (public.is_staff());
revoke all on public.assignment_zones from anon, authenticated;
grant select on public.assignment_zones to authenticated;

create function public.norm_city(p text) returns text
language sql immutable set search_path = '' as $$
  select nullif(btrim(regexp_replace(translate(lower(coalesce(p,'')), 'àâäéèêëîïôöùûüç-''', 'aaaeeeeiioouuuc  '), '\s+', ' ', 'g')), '')
$$;

-- Remplace les zones d'un commercial. Une même zone ne peut appartenir qu'à un seul commercial.
create function public.set_zones(p_user uuid, p_postal text[], p_cities text[]) returns void
language plpgsql security definer set search_path = '' as $$
declare v text; other uuid;
begin
  if public.current_role_name() <> 'admin' then raise exception 'FORBIDDEN'; end if;
  if not exists (select 1 from public.profiles where id = p_user and role = 'commercial') then
    raise exception 'TARGET_NOT_ACTIVE_SALESPERSON';
  end if;
  delete from public.assignment_zones where user_id = p_user;
  foreach v in array coalesce(p_postal, '{}') loop
    v := regexp_replace(v, '\s', '', 'g');
    if v = '' then continue; end if;
    if v !~ '^[0-9]{2,5}$' then raise exception 'BAD_ZONE %', v; end if;
    select user_id into other from public.assignment_zones where kind='postal' and value=v;
    if other is not null then raise exception 'ZONE_TAKEN %', v; end if;
    insert into public.assignment_zones (user_id, kind, value) values (p_user, 'postal', v);
  end loop;
  foreach v in array coalesce(p_cities, '{}') loop
    v := public.norm_city(v);
    if v is null then continue; end if;
    select user_id into other from public.assignment_zones where kind='city' and value=v;
    if other is not null then raise exception 'ZONE_TAKEN %', v; end if;
    insert into public.assignment_zones (user_id, kind, value) values (p_user, 'city', v);
  end loop;
  insert into public.audit_log (actor, action, entity, entity_id, details)
    values (auth.uid(), 'set_zones', 'profiles', p_user::text, jsonb_build_object('postal', p_postal, 'cities', p_cities));
end $$;

-- Commercial actif de la zone : code postal le plus précis d'abord, sinon ville. Ambigu ou inconnu : null.
create function public.zone_owner(p_cp text, p_address text, p_city text) returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare cp text; u uuid; n int; best int;
begin
  cp := coalesce(nullif(regexp_replace(coalesce(p_cp,''), '\s', '', 'g'), ''), substring(coalesce(p_address,'') from '\m[0-9]{5}\M'));
  if cp is not null then
    select max(length(value)) into best from public.assignment_zones z join public.profiles p on p.id = z.user_id
      where z.kind='postal' and p.active and p.role='commercial' and cp like z.value || '%';
    if best is not null then
      select count(distinct z.user_id), min(z.user_id::text)::uuid into n, u from public.assignment_zones z join public.profiles p on p.id = z.user_id
        where z.kind='postal' and p.active and p.role='commercial' and cp like z.value || '%' and length(z.value) = best;
      if n = 1 then return u; else return null; end if;
    end if;
  end if;
  select count(distinct z.user_id), min(z.user_id::text)::uuid into n, u from public.assignment_zones z join public.profiles p on p.id = z.user_id
    where z.kind='city' and p.active and p.role='commercial'
      and z.value in (public.norm_city(p_city), public.norm_city(p_address));
  if n = 1 then return u; end if;
  return null;
end $$;

-- Attribue une demande selon sa zone (usage interne). Retourne vrai si attribuée.
create function public.zone_assign_one(p_request bigint, p_by uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare r public.requests; c public.contacts; u uuid;
begin
  select * into r from public.requests where id = p_request for update;
  if not found or r.assigned_to is not null or r.archived or r.quality in ('doublon','spam')
     or r.stage in ('cloture_sans_vente','vente_faite') then return false; end if;
  select * into c from public.contacts where id = r.contact_id;
  if (c.phone_norm is null and c.email_norm is null) or c.display_name is null then return false; end if;
  u := public.zone_owner(c.postal_code, c.address, c.city);
  if u is null then return false; end if;
  insert into public.assignments (request_id, to_user, by_user, reason)
    values (p_request, u, p_by, 'Attribution automatique par zone');
  update public.requests set assigned_to = u, assigned_at = now(), updated_at = now(), version = version + 1,
    stage = case when stage = 'recu' then 'a_contacter' else stage end where id = p_request;
  return true;
end $$;

create function public.apply_zones() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0; total int := 0;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  for r in select id from public.requests where assigned_to is null and not archived
      and quality not in ('doublon','spam') and stage not in ('cloture_sans_vente','vente_faite') order by id loop
    total := total + 1;
    if public.zone_assign_one(r.id, auth.uid()) then n := n + 1; end if;
  end loop;
  insert into public.audit_log (actor, action, entity, details)
    values (auth.uid(), 'apply_zones', 'requests', jsonb_build_object('assigned', n, 'examined', total));
  return jsonb_build_object('assigned', n, 'examined', total);
end $$;

-- Nouvelle demande : attribution automatique si la zone est connue et le dossier complet.
create or replace function public.create_request(
  p_display_name text, p_phone text, p_email text, p_source_id bigint,
  p_source_label text default null, p_city text default null, p_postal_code text default null,
  p_address text default null, p_work_type_ids bigint[] default '{}',
  p_description text default null, p_received_on date default null, p_raw_text text default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare c bigint; r bigint; w bigint;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  insert into public.contacts (display_name, phone_raw, phone_norm, email_raw, email_norm,
      address, postal_code, city, created_by)
    values (nullif(btrim(p_display_name),''), p_phone, public.normalize_phone(p_phone), p_email,
      public.normalize_email(p_email), p_address, p_postal_code, p_city, auth.uid())
    returning id into c;
  insert into public.requests (contact_id, source_id, source_label_original, received_on,
      description, raw_text, created_by)
    values (c, p_source_id, p_source_label, p_received_on, p_description, p_raw_text, auth.uid())
    returning id into r;
  foreach w in array p_work_type_ids loop
    insert into public.request_work_types values (r, w) on conflict do nothing;
  end loop;
  insert into public.audit_log (actor, action, entity, entity_id)
    values (auth.uid(), 'create_request', 'requests', r::text);
  perform public.zone_assign_one(r, auth.uid());
  return r;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.set_zones, public.apply_zones, public.norm_city to authenticated;
revoke execute on function public.zone_owner, public.zone_assign_one from authenticated;
grant execute on function public.create_request to authenticated;
