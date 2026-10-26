-- Règles de zones rattachées à un nom de commercial (comme dans le classeur), même sans compte.
-- Dès qu'un compte au même nom existe, il est relié automatiquement. Une règle retirée est désactivée (jamais effacée).
-- Remplace l'ancienne table assignment_zones (restée vide et inutilisée).
create table public.zone_rules (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('postal','city')),
  value text not null,
  label text not null,
  user_id uuid references public.profiles(id),
  active boolean not null default true,
  unique (kind, value)
);
alter table public.zone_rules enable row level security;
create policy zone_rules_read on public.zone_rules for select to authenticated using (public.is_staff());
revoke all on public.zone_rules from anon, authenticated;
grant select on public.zone_rules to authenticated;

-- Signature d'un nom : mots normalisés et triés (« JOYEUX Alexis » = « Alexis Joyeux »)
create function public.name_sig(p text) returns text
language sql immutable set search_path = '' as $$
  select coalesce(string_agg(w, ' ' order by w), '') from unnest(string_to_array(coalesce(public.norm_city(p), ''), ' ')) w
$$;

create function public.link_zones_to_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.role = 'commercial' then
    update public.zone_rules set user_id = new.id
      where label is not null and user_id is null and public.name_sig(label) = public.name_sig(new.full_name);
  end if;
  return new;
end $$;
create trigger profiles_link_zones after insert or update of full_name, role on public.profiles
  for each row execute function public.link_zones_to_profile();

-- Remplace les zones d'un commercial désigné par son nom.
create function public.set_zone_label(p_label text, p_postal text[], p_cities text[]) returns void
language plpgsql security definer set search_path = '' as $$
declare v text; sig text := public.name_sig(p_label); other text; uid uuid;
begin
  if public.current_role_name() <> 'admin' then raise exception 'FORBIDDEN'; end if;
  if sig = '' then raise exception 'NAME_REQUIRED'; end if;
  select id into uid from public.profiles where role = 'commercial' and public.name_sig(full_name) = sig limit 1;
  update public.zone_rules set active = false where label is not null and public.name_sig(label) = sig;
  foreach v in array coalesce(p_postal, '{}') loop
    v := regexp_replace(v, '\s', '', 'g');
    if v = '' then continue; end if;
    if v !~ '^[0-9]{2,5}$' then raise exception 'BAD_ZONE %', v; end if;
    select label into other from public.zone_rules where kind = 'postal' and value = v and active and public.name_sig(label) <> sig;
    if other is not null then raise exception 'ZONE_TAKEN %', v; end if;
    insert into public.zone_rules (kind, value, label, user_id, active) values ('postal', v, btrim(p_label), uid, true)
      on conflict (kind, value) do update set label = btrim(p_label), user_id = uid, active = true;
  end loop;
  foreach v in array coalesce(p_cities, '{}') loop
    v := public.norm_city(v);
    if v is null then continue; end if;
    select label into other from public.zone_rules where kind = 'city' and value = v and active and public.name_sig(label) <> sig;
    if other is not null then raise exception 'ZONE_TAKEN %', v; end if;
    insert into public.zone_rules (kind, value, label, user_id, active) values ('city', v, btrim(p_label), uid, true)
      on conflict (kind, value) do update set label = btrim(p_label), user_id = uid, active = true;
  end loop;
  insert into public.audit_log (actor, action, entity, entity_id, details)
    values (auth.uid(), 'set_zone_label', 'zone_rules', p_label, jsonb_build_object('postal', p_postal, 'cities', p_cities));
end $$;

-- Import d'un tableau de règles [{postal, label}] : le tableau fait foi (une règle existante change de commercial).
create function public.set_zone_rules(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare x jsonb; v text; l text; uid uuid; n int := 0; bad text[] := '{}';
begin
  if public.current_role_name() <> 'admin' then raise exception 'FORBIDDEN'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 5000 then raise exception 'BAD_ROWS'; end if;
  for x in select * from jsonb_array_elements(p_rows) loop
    v := regexp_replace(coalesce(x->>'postal',''), '\s', '', 'g');
    l := btrim(coalesce(x->>'label',''));
    if v ~ '^[0-9]{4}$' then v := '0' || v; end if;
    if v !~ '^[0-9]{2,5}$' or public.name_sig(l) = '' then bad := bad || coalesce(x->>'postal','?'); continue; end if;
    select id into uid from public.profiles where role = 'commercial' and public.name_sig(full_name) = public.name_sig(l) limit 1;
    insert into public.zone_rules (kind, value, label, user_id, active) values ('postal', v, l, uid, true)
      on conflict (kind, value) do update set label = l, user_id = uid, active = true;
    n := n + 1;
  end loop;
  insert into public.audit_log (actor, action, entity, details)
    values (auth.uid(), 'set_zone_rules', 'zone_rules', jsonb_build_object('rows', n, 'rejected', bad));
  return jsonb_build_object('applied', n, 'rejected', to_jsonb(bad));
end $$;

-- Propriétaire d'une zone : règle la plus précise (code postal), sinon ville. Sans compte actif, ambigu ou inconnu : null.
create or replace function public.zone_owner(p_cp text, p_address text, p_city text) returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare cp text; best int; n int; holder text; u uuid;
begin
  cp := coalesce(nullif(regexp_replace(coalesce(p_cp,''), '\s', '', 'g'), ''), substring(coalesce(p_address,'') from '\m[0-9]{5}\M'));
  if cp is not null then
    select max(length(value)) into best from public.zone_rules where kind = 'postal' and active and cp like value || '%';
    if best is not null then
      select count(distinct coalesce(user_id::text, 'n:' || public.name_sig(label))), min(coalesce(user_id::text, 'n:' || public.name_sig(label)))
        into n, holder from public.zone_rules
        where kind = 'postal' and active and cp like value || '%' and length(value) = best;
      if n <> 1 or holder like 'n:%' then return null; end if;
      u := holder::uuid;
      return (select id from public.profiles where id = u and active and role = 'commercial');
    end if;
  end if;
  select count(distinct coalesce(user_id::text, 'n:' || public.name_sig(label))), min(coalesce(user_id::text, 'n:' || public.name_sig(label)))
    into n, holder from public.zone_rules
    where kind = 'city' and active and value in (public.norm_city(p_city), public.norm_city(p_address));
  if n <> 1 or holder is null or holder like 'n:%' then return null; end if;
  u := holder::uuid;
  return (select id from public.profiles where id = u and active and role = 'commercial');
end $$;

-- Import historique : code postal et ville conservés dans la fiche contact.
create or replace function public.import_rows(p_name text, p_hash text, p_force boolean, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare b bigint; x jsonb; c bigint; r bigint; w text; n int := 0; qual public.request_quality;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 5000 then raise exception 'BAD_ROWS'; end if;
  if exists (select 1 from public.import_batches where file_hash = p_hash) and not coalesce(p_force, false) then
    raise exception 'ALREADY_IMPORTED';
  end if;
  insert into public.import_batches (file_hash, file_name, created_by) values (p_hash, p_name, auth.uid()) returning id into b;
  for x in select * from jsonb_array_elements(p_rows) loop
    insert into public.contacts (display_name, phone_raw, phone_norm, email_raw, email_norm, address, postal_code, city, created_by)
      values (nullif(btrim(x->>'name'),''), x->>'phone', public.normalize_phone(x->>'phone'), x->>'email',
        public.normalize_email(x->>'email'), x->>'address', nullif(x->>'postal_code',''), nullif(x->>'city',''), auth.uid()) returning id into c;
    qual := case when (x->>'duplicate_of') is not null then 'doublon' else 'a_verifier' end;
    insert into public.requests (contact_id, source_id, source_label_original, received_on, quality, stage, last_result,
        close_reason, assigned_to, assigned_at, rdv_on, hist_note, hist_calls, alerts, duplicate_of, import_batch_id, created_by)
      values (c, nullif(x->>'source_id','')::bigint, x->>'source_label', null, qual,
        coalesce(nullif(x->>'stage',''),'recu')::public.request_stage, nullif(x->>'last_result','')::public.contact_result,
        nullif(x->>'close_reason','')::public.contact_result, nullif(x->>'commercial_id','')::uuid,
        nullif(x->>'assigned_on','')::timestamptz, nullif(x->>'rdv_on','')::date, x->>'hist_note', x->>'hist_calls',
        coalesce(array(select jsonb_array_elements_text(coalesce(x->'alerts','[]'::jsonb))), '{}'),
        nullif(x->>'duplicate_of','')::bigint, b, auth.uid()) returning id into r;
    for w in select jsonb_array_elements_text(coalesce(x->'works','[]'::jsonb)) loop
      insert into public.request_work_types select r, id from public.work_types where name = w on conflict do nothing;
    end loop;
    if nullif(x->>'commercial_id','') is not null then
      insert into public.assignments (request_id, to_user, by_user, reason)
        values (r, (x->>'commercial_id')::uuid, auth.uid(), 'Reprise historique');
    end if;
    n := n + 1;
  end loop;
  update public.import_batches set row_count = n where id = b;
  insert into public.audit_log (actor, action, entity, entity_id, details)
    values (auth.uid(), 'import', 'import_batches', b::text, jsonb_build_object('rows', n, 'file', p_name));
  return jsonb_build_object('batch_id', b, 'created', n);
end $$;

-- Référentiels vus dans le classeur d'octobre (variantes exactes conservées)
insert into public.work_types (name) values ('Rénovation énergétique') on conflict (name) do nothing;
insert into public.sources (name) values
  ('Contact téléphonique GOOGLE'),('Contact téléphonique PAGES JAUNES'),('Formulaire climatisation Samatan'),
  ('Formulaire climatisation Toulouse'),('Formulaire pompes à chaleur Toulouse'),
  ('Formulaire panneaux photovoltaïques Antoine DUPONT'),('Formulaire panneaux solaires Toulouse'),
  ('Formulaire panneaux solaires Narbonne'),('Formulaire panneaux solaires Perpignan'),
  ('Campagne Batterie SOLPLANET'),('Formulaire Batterie'),('Leads Solaredge')
on conflict (name) do nothing;

revoke execute on all functions in schema public from public, anon;
revoke execute on function public.set_zones from authenticated;
grant execute on function public.set_zone_label, public.set_zone_rules, public.name_sig, public.import_rows to authenticated;
revoke execute on function public.zone_owner, public.zone_assign_one, public.link_zones_to_profile from authenticated;
