-- Lot 1 : socle du CRM C2e (rôles, référentiels, contacts, demandes, attribution).
-- Règle : les droits sont appliqués par la base (RLS + fonctions). Aucune écriture directe
-- depuis le navigateur : tout passe par les fonctions ci-dessous.

create type public.app_role as enum ('admin', 'secretariat', 'commercial');
create type public.request_stage as enum
  ('recu','a_contacter','contact_etabli','rdv_pris','devis_a_faire','devis_realise','vente_faite','cloture_sans_vente');
create type public.contact_result as enum
  ('pas_de_reponse','a_rappeler','pas_interesse','trop_loin','injoignable','faux_numero','trop_tard','emploi_formation','autre');
create type public.request_quality as enum ('a_verifier','valide','doublon','spam');
create type public.next_action as enum
  ('appeler','rappeler','envoyer_mail','realiser_devis','relancer_devis','aucune');

-- Utilisateurs (un profil par compte d'authentification, créé par un administrateur)
create table public.profiles (
  id uuid primary key references auth.users(id),
  full_name text not null,
  role public.app_role not null default 'commercial',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.sources (
  id bigint generated always as identity primary key,
  name text not null unique,          -- libellé exact du classeur
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table public.work_types (
  id bigint generated always as identity primary key,
  name text not null unique,
  active boolean not null default true
);

-- Une fiche contact = une personne ou une entreprise
create table public.contacts (
  id bigint generated always as identity primary key,
  display_name text,
  first_name text,
  last_name text,
  company text,
  phone_raw text,
  phone_norm text,
  email_raw text,
  email_norm text,
  address text,
  postal_code text,
  city text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create index on public.contacts (phone_norm);
create index on public.contacts (email_norm);

-- Une demande = un projet commercial (un contact peut en avoir plusieurs)
create table public.requests (
  id bigint generated always as identity primary key,
  contact_id bigint not null references public.contacts(id),
  source_id bigint references public.sources(id),
  source_label_original text,
  received_on date,                    -- null = date inconnue
  description text,
  declared_budget numeric,
  availability text,
  raw_text text,
  quality public.request_quality not null default 'a_verifier',
  stage public.request_stage not null default 'recu',
  last_result public.contact_result,
  next_action public.next_action,
  next_action_due timestamptz,
  assigned_to uuid references public.profiles(id),
  assigned_at timestamptz,
  archived boolean not null default false,
  version integer not null default 1,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.requests (assigned_to);
create index on public.requests (contact_id);

create table public.request_work_types (
  request_id bigint not null references public.requests(id),
  work_type_id bigint not null references public.work_types(id),
  primary key (request_id, work_type_id)
);

-- Historique des attributions (distinct du responsable courant)
create table public.assignments (
  id bigint generated always as identity primary key,
  request_id bigint not null references public.requests(id),
  from_user uuid references public.profiles(id),
  to_user uuid references public.profiles(id),
  by_user uuid references public.profiles(id),
  reason text,
  override_reason text,
  at timestamptz not null default now()
);

-- Journal des actions sensibles (changements de rôle, désactivations, etc.)
create table public.audit_log (
  id bigint generated always as identity primary key,
  actor uuid,
  action text not null,
  entity text not null,
  entity_id text,
  details jsonb,
  at timestamptz not null default now()
);

-- ---------- Fonctions utilitaires ----------
create function public.current_role_name() returns public.app_role
language sql stable security definer set search_path = '' as $$
  select role from public.profiles where id = auth.uid() and active
$$;

create function public.is_staff() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(public.current_role_name() in ('admin','secretariat'), false)
$$;

-- Téléphone : 06, 07 et +33 deviennent équivalents ; les autres préfixes sont conservés.
create function public.normalize_phone(p text) returns text
language plpgsql immutable set search_path = '' as $$
declare s text;
begin
  if p is null then return null; end if;
  s := regexp_replace(p, '[^0-9+]', '', 'g');
  if s = '' then return null; end if;
  if s like '0033%' then s := '+' || substr(s, 3); end if;
  if s like '+33%' then s := '0' || substr(s, 4);
  elsif s like '+%' then return s;
  elsif s like '33%' and length(s) = 11 then s := '0' || substr(s, 3);
  end if;
  return s;
end $$;

create function public.normalize_email(p text) returns text
language sql immutable set search_path = '' as $$
  select nullif(lower(btrim(p)), '')
$$;

-- ---------- Lecture (RLS) ----------
alter table public.profiles enable row level security;
alter table public.sources enable row level security;
alter table public.work_types enable row level security;
alter table public.contacts enable row level security;
alter table public.requests enable row level security;
alter table public.request_work_types enable row level security;
alter table public.assignments enable row level security;
alter table public.audit_log enable row level security;

create policy profiles_read on public.profiles for select to authenticated
  using (public.is_staff() or id = auth.uid());
create policy sources_read on public.sources for select to authenticated using (true);
create policy work_types_read on public.work_types for select to authenticated using (true);

create policy requests_read on public.requests for select to authenticated
  using (public.is_staff() or (assigned_to = auth.uid() and public.current_role_name() = 'commercial'));
create policy contacts_read on public.contacts for select to authenticated
  using (public.is_staff() or exists (
    select 1 from public.requests r
    where r.contact_id = contacts.id and r.assigned_to = auth.uid()
      and public.current_role_name() = 'commercial'));
create policy rwt_read on public.request_work_types for select to authenticated
  using (exists (select 1 from public.requests r where r.id = request_id));
create policy assignments_read on public.assignments for select to authenticated
  using (public.is_staff() or to_user = auth.uid());
create policy audit_read on public.audit_log for select to authenticated
  using (public.current_role_name() = 'admin');

-- Aucune écriture directe : seules les fonctions ci-dessous écrivent.
revoke all on all tables in schema public from anon, authenticated;
grant select on public.profiles, public.sources, public.work_types, public.contacts,
  public.requests, public.request_work_types, public.assignments, public.audit_log to authenticated;

-- Dossiers à réattribuer (commercial désactivé) : réservé au personnel via RLS de requests
create view public.requests_to_reassign with (security_invoker = true) as
  select r.* from public.requests r
  join public.profiles p on p.id = r.assigned_to
  where not p.active and not r.archived and r.stage not in ('vente_faite','cloture_sans_vente');
grant select on public.requests_to_reassign to authenticated;

-- ---------- Écriture par fonctions ----------
create function public.create_request(
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
  return r;
end $$;

-- Attribution / réattribution. Exige un moyen de contact et un nom d'affichage,
-- sauf dérogation motivée d'un administrateur.
create function public.assign_requests(
  p_request_ids bigint[], p_to uuid, p_reason text default null, p_override_reason text default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare rid bigint; rq public.requests; ct public.contacts; n integer := 0;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  if not exists (select 1 from public.profiles where id = p_to and active and role = 'commercial') then
    raise exception 'TARGET_NOT_ACTIVE_SALESPERSON';
  end if;
  foreach rid in array p_request_ids loop
    select * into rq from public.requests where id = rid for update;
    if not found then raise exception 'REQUEST_NOT_FOUND %', rid; end if;
    select * into ct from public.contacts where id = rq.contact_id;
    if (ct.phone_norm is null and ct.email_norm is null) or ct.display_name is null then
      if p_override_reason is null or public.current_role_name() <> 'admin' then
        raise exception 'INCOMPLETE_CONTACT %', rid;
      end if;
    end if;
    if rq.assigned_to is not distinct from p_to then continue; end if;
    insert into public.assignments (request_id, from_user, to_user, by_user, reason, override_reason)
      values (rid, rq.assigned_to, p_to, auth.uid(), p_reason, p_override_reason);
    update public.requests set assigned_to = p_to, assigned_at = now(), updated_at = now(),
      version = version + 1,
      stage = case when stage = 'recu' then 'a_contacter' else stage end,
      next_action = coalesce(next_action, 'appeler')
      where id = rid;
    n := n + 1;
  end loop;
  insert into public.audit_log (actor, action, entity, details)
    values (auth.uid(), 'assign_requests', 'requests',
      jsonb_build_object('ids', p_request_ids, 'to', p_to, 'count', n));
  return n;
end $$;

-- Modification des coordonnées avec contrôle de version (édition concurrente).
create function public.update_contact_info(
  p_request_id bigint, p_expected_version integer, p_patch jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare rq public.requests; k text;
begin
  select * into rq from public.requests where id = p_request_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not (public.is_staff() or (rq.assigned_to = auth.uid() and public.current_role_name() = 'commercial')) then
    raise exception 'FORBIDDEN';
  end if;
  if rq.version <> p_expected_version then raise exception 'CONFLICT'; end if;
  for k in select jsonb_object_keys(p_patch) loop
    if k not in ('display_name','first_name','last_name','company','phone_raw','email_raw','address','postal_code','city') then
      raise exception 'FIELD_NOT_ALLOWED %', k;
    end if;
  end loop;
  update public.contacts c set
    display_name = case when p_patch ? 'display_name' then p_patch->>'display_name' else c.display_name end,
    first_name   = case when p_patch ? 'first_name'   then p_patch->>'first_name'   else c.first_name end,
    last_name    = case when p_patch ? 'last_name'    then p_patch->>'last_name'    else c.last_name end,
    company      = case when p_patch ? 'company'      then p_patch->>'company'      else c.company end,
    phone_raw    = case when p_patch ? 'phone_raw'    then p_patch->>'phone_raw'    else c.phone_raw end,
    email_raw    = case when p_patch ? 'email_raw'    then p_patch->>'email_raw'    else c.email_raw end,
    address      = case when p_patch ? 'address'      then p_patch->>'address'      else c.address end,
    postal_code  = case when p_patch ? 'postal_code'  then p_patch->>'postal_code'  else c.postal_code end,
    city         = case when p_patch ? 'city'         then p_patch->>'city'         else c.city end
    where c.id = rq.contact_id;
  update public.contacts set phone_norm = public.normalize_phone(phone_raw),
    email_norm = public.normalize_email(email_raw) where id = rq.contact_id;
  update public.requests set version = version + 1, updated_at = now() where id = p_request_id;
  insert into public.audit_log (actor, action, entity, entity_id, details)
    values (auth.uid(), 'update_contact_info', 'requests', p_request_id::text, p_patch);
  return rq.version + 1;
end $$;

-- Gestion des comptes (administrateur uniquement, journalisée)
create function public.admin_set_role(p_user uuid, p_role public.app_role) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if public.current_role_name() <> 'admin' then raise exception 'FORBIDDEN'; end if;
  if p_user = auth.uid() then raise exception 'CANNOT_CHANGE_OWN_ROLE'; end if;
  update public.profiles set role = p_role where id = p_user;
  insert into public.audit_log (actor, action, entity, entity_id, details)
    values (auth.uid(), 'set_role', 'profiles', p_user::text, jsonb_build_object('role', p_role));
end $$;

create function public.admin_set_active(p_user uuid, p_active boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if public.current_role_name() <> 'admin' then raise exception 'FORBIDDEN'; end if;
  if p_user = auth.uid() then raise exception 'CANNOT_DEACTIVATE_SELF'; end if;
  update public.profiles set active = p_active where id = p_user;
  insert into public.audit_log (actor, action, entity, entity_id, details)
    values (auth.uid(), 'set_active', 'profiles', p_user::text, jsonb_build_object('active', p_active));
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.create_request, public.assign_requests, public.update_contact_info,
  public.admin_set_role, public.admin_set_active, public.normalize_phone, public.normalize_email,
  public.current_role_name, public.is_staff to authenticated;

-- ---------- Référentiels initiaux (valeurs exactes du classeur) ----------
insert into public.work_types (name) values
  ('Photovoltaïque'),('Rénovation globale'),('Isolation'),('Ballon thermodynamique'),
  ('PAC air/eau'),('Ballon solaire'),('VMC'),('Batterie photovoltaïque'),
  ('Chauffe-eau électrique'),('PAC air/air');

insert into public.sources (name) values
  ('Formulaire estimation de votre projet sur le site'),('Leads Dualsun'),
  ('Contact téléphonique RECOMMANDATION'),('Formulaire climatisation Occitanie'),
  ('Formulaire Aide Toulouse Métropole'),('Contact Mail'),
  ('Formulaire installation pompes à chaleur sur le site'),('Lead Facebook'),
  ('Formulaire panneaux photovoltaïques Occitanie'),('Formulaire entretien sur le site'),
  ('Formulaire panneaux solaires Occitanie'),
  ('Téléphone Google'),('Pages Jaunes'),('Habitat Presto'),('Presencity'),('Kolink'),
  ('Effy Pro'),('Campagne batterie'),('Leadcall'),('SolarEdge');
