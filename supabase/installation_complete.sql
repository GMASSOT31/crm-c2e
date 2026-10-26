-- CRM C2e : installation complète. À coller en une fois dans Supabase > SQL Editor > Run.

-- ===== supabase/migrations/20261026000001_socle.sql =====
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

-- ===== supabase/migrations/20261026000002_activites.sql =====
-- Lot 2 : activités (appels, rappels, RDV, devis, ventes), tâches, compteurs et relance après 3 appels.
create type public.activity_type as enum
  ('no_answer','contact','callback','appointment','quote','sale','close','reopen','note','mail');
create type public.task_kind as enum ('call','callback','mail','quote','quote_followup');
create type public.task_status as enum ('open','done','cancelled');

alter table public.requests
  add column rdv_on date, add column rdv_time time, add column rdv_time_tbd boolean not null default false,
  add column opt_out boolean not null default false,
  add column close_reason public.contact_result,
  add column sale_on date, add column sale_amount numeric, add column sale_vat text check (sale_vat in ('HT','TTC')),
  add column quote_ref text;

create table public.activities (
  id bigint generated always as identity primary key,
  request_id bigint not null references public.requests(id),
  type public.activity_type not null,
  author uuid references public.profiles(id),
  at timestamptz not null default now(),
  note text,
  data jsonb not null default '{}',
  client_token text unique,           -- neutralise le double clic / la requête répétée
  corrects bigint references public.activities(id)  -- correction : garde la trace de la valeur précédente
);
create index on public.activities (request_id, id);

create table public.tasks (
  id bigint generated always as identity primary key,
  request_id bigint not null references public.requests(id),
  kind public.task_kind not null,
  due_at timestamptz,
  status public.task_status not null default 'open',
  seq_key text unique,                -- une seule tâche mail par séquence d'appels
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create index on public.tasks (request_id, status);

alter table public.activities enable row level security;
alter table public.tasks enable row level security;
create policy act_read on public.activities for select to authenticated
  using (exists (select 1 from public.requests r where r.id = request_id));
create policy task_read on public.tasks for select to authenticated
  using (exists (select 1 from public.requests r where r.id = request_id));
revoke all on public.activities, public.tasks from anon, authenticated;
grant select on public.activities, public.tasks to authenticated;

-- Compteur : appels sans réponse consécutifs depuis le dernier contact établi (+ total historique)
create function public.call_counters(p_request bigint) returns table(consecutive int, total int, seq bigint)
language sql stable security definer set search_path = '' as $$
  with last_c as (select coalesce(max(id),0) id from public.activities where request_id=p_request and type='contact')
  select (select count(*)::int from public.activities a, last_c where a.request_id=p_request and a.type='no_answer' and a.id>last_c.id),
         (select count(*)::int from public.activities where request_id=p_request and type='no_answer'),
         (select id from last_c)
$$;

create function public.can_act(p_request bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.requests r where r.id = p_request and not r.archived and
    (public.is_staff() or (r.assigned_to = auth.uid() and public.current_role_name() = 'commercial')))
$$;

-- Verrou + contrôles communs. Retourne la demande verrouillée.
create function public.lock_request(p_request bigint) returns public.requests
language plpgsql security definer set search_path = '' as $$
declare r public.requests;
begin
  if not public.can_act(p_request) then raise exception 'FORBIDDEN'; end if;
  select * into r from public.requests where id = p_request for update;
  if r.stage in ('cloture_sans_vente') then raise exception 'REQUEST_CLOSED'; end if;
  return r;
end $$;

create function public.cancel_open_tasks(p_request bigint, p_kinds public.task_kind[]) returns void
language sql security definer set search_path = '' as $$
  update public.tasks set status='cancelled'
  where request_id=p_request and status='open' and kind = any(p_kinds)
$$;

-- Appel sans réponse : une validation, un événement, compteur recalculé, tâche mail au 3e appel.
create function public.record_no_answer(p_request bigint, p_note text default null, p_token text default null)
returns table(consecutive int, total int, mail_task_created boolean)
language plpgsql security definer set search_path = '' as $$
declare r public.requests; c record; created boolean := false; n int;
begin
  r := public.lock_request(p_request);
  if p_token is not null and exists (select 1 from public.activities where client_token = p_token) then
    select * into c from public.call_counters(p_request);
    return query select c.consecutive, c.total, false; return;
  end if;
  insert into public.activities (request_id, type, author, note, client_token)
    values (p_request, 'no_answer', auth.uid(), p_note, p_token);
  select * into c from public.call_counters(p_request);
  -- l'étape n'est jamais rétrogradée : un appel sans réponse après devis garde « devis_realise »
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

create function public.record_contact(p_request bigint, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.lock_request(p_request);
  insert into public.activities (request_id, type, author, note) values (p_request, 'contact', auth.uid(), p_note);
  update public.requests set last_result=null, version=version+1, updated_at=now(), next_action=null,
    stage = case when stage in ('recu','a_contacter') then 'contact_etabli' else stage end
    where id = p_request;
  -- un contact établi interrompt la séquence et annule la relance mail en attente
  perform public.cancel_open_tasks(p_request, array['call','callback','mail']::public.task_kind[]);
end $$;

create function public.schedule_callback(p_request bigint, p_due timestamptz, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_due is null then raise exception 'DUE_REQUIRED'; end if;
  perform public.lock_request(p_request);
  insert into public.activities (request_id, type, author, note, data)
    values (p_request, 'callback', auth.uid(), p_note, jsonb_build_object('due', p_due));
  perform public.cancel_open_tasks(p_request, array['call','callback']::public.task_kind[]);
  insert into public.tasks (request_id, kind, due_at, created_by) values (p_request, 'callback', p_due, auth.uid());
  update public.requests set last_result='a_rappeler', next_action='rappeler'::public.next_action, next_action_due=p_due,
    version=version+1, updated_at=now() where id = p_request;
end $$;

create function public.book_appointment(p_request bigint, p_date date, p_time time default null,
  p_time_tbd boolean default false, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_date is null or (p_time is null and not p_time_tbd) then raise exception 'DATE_AND_TIME_REQUIRED'; end if;
  perform public.lock_request(p_request);
  insert into public.activities (request_id, type, author, note, data)
    values (p_request, 'appointment', auth.uid(), p_note, jsonb_build_object('date', p_date, 'time', p_time, 'tbd', p_time_tbd));
  update public.requests set rdv_on=p_date, rdv_time=p_time, rdv_time_tbd=p_time_tbd, version=version+1, updated_at=now(),
    stage = case when stage in ('recu','a_contacter','contact_etabli') then 'rdv_pris' else stage end
    where id = p_request;
  perform public.cancel_open_tasks(p_request, array['call','callback','mail']::public.task_kind[]);
end $$;

create function public.record_quote(p_request bigint, p_ref text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.lock_request(p_request);
  insert into public.activities (request_id, type, author, data) values (p_request, 'quote', auth.uid(), jsonb_build_object('ref', p_ref));
  update public.requests set quote_ref=p_ref, version=version+1, updated_at=now(),
    stage = case when stage <> 'vente_faite' then 'devis_realise' else stage end where id = p_request;
end $$;

create function public.record_sale(p_request bigint, p_date date, p_amount numeric default null, p_vat text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_date is null then raise exception 'SALE_DATE_REQUIRED'; end if;
  if p_amount is not null and p_vat is null then raise exception 'VAT_MODE_REQUIRED'; end if;
  perform public.lock_request(p_request);
  insert into public.activities (request_id, type, author, data)
    values (p_request, 'sale', auth.uid(), jsonb_build_object('date', p_date, 'amount', p_amount, 'vat', p_vat));
  update public.requests set stage='vente_faite', sale_on=p_date, sale_amount=p_amount, sale_vat=p_vat,
    next_action=null, version=version+1, updated_at=now() where id = p_request;
  perform public.cancel_open_tasks(p_request, array['call','callback','mail','quote_followup']::public.task_kind[]);
end $$;

-- Clôture : motif obligatoire, relances annulées. Réouverture : administrateur, avec motif.
create function public.close_request(p_request bigint, p_reason public.contact_result, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_reason is null then raise exception 'REASON_REQUIRED'; end if;
  perform public.lock_request(p_request);
  insert into public.activities (request_id, type, author, note, data) values (p_request, 'close', auth.uid(), p_note, jsonb_build_object('reason', p_reason));
  update public.requests set stage='cloture_sans_vente', close_reason=p_reason, last_result=p_reason,
    next_action=null, version=version+1, updated_at=now() where id = p_request;
  perform public.cancel_open_tasks(p_request, array['call','callback','mail','quote','quote_followup']::public.task_kind[]);
end $$;

create function public.reopen_request(p_request bigint, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if public.current_role_name() <> 'admin' then raise exception 'FORBIDDEN'; end if;
  if coalesce(btrim(p_reason),'') = '' then raise exception 'REASON_REQUIRED'; end if;
  update public.requests set stage='a_contacter', close_reason=null, version=version+1, updated_at=now() where id = p_request;
  insert into public.activities (request_id, type, author, note) values (p_request, 'reopen', auth.uid(), p_reason);
end $$;

-- Opposition au contact : bloque et annule toute relance mail
create function public.set_opt_out(p_request bigint, p_value boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  update public.requests set opt_out=p_value, version=version+1 where id=p_request;
  if p_value then perform public.cancel_open_tasks(p_request, array['mail']::public.task_kind[]); end if;
  insert into public.audit_log (actor, action, entity, entity_id, details)
    values (auth.uid(), 'set_opt_out', 'requests', p_request::text, jsonb_build_object('value', p_value));
end $$;

-- Pourquoi la relance mail est bloquée (null = autorisée)
create function public.mail_block_reason(p_request bigint) returns text
language sql stable security definer set search_path = '' as $$
  select case
    when r.stage='cloture_sans_vente' then 'Dossier clôturé'
    when r.quality in ('doublon','spam') then 'Dossier marqué doublon ou spam'
    when r.opt_out then 'Opposition au contact enregistrée'
    when r.stage in ('rdv_pris','devis_a_faire','devis_realise','vente_faite') then 'Un rendez-vous a été pris'
    when c.email_norm is null or c.email_norm !~ '^[^\s@,]+@[^\s@,]+\.[a-z]{2,}$' then 'Email manquant ou à corriger'
    end
  from public.requests r join public.contacts c on c.id=r.contact_id
  where r.id=p_request and public.can_act(p_request)
$$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.call_counters, public.can_act, public.record_no_answer, public.record_contact,
  public.schedule_callback, public.book_appointment, public.record_quote, public.record_sale,
  public.close_request, public.reopen_request, public.set_opt_out, public.mail_block_reason to authenticated;
revoke execute on function public.lock_request, public.cancel_open_tasks from authenticated;

-- ===== supabase/migrations/20261026000003_equipe_qualite.sql =====
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

-- ===== supabase/migrations/20261026000004_journal_export.sql =====
-- Journalisation des exports (utilisateur et périmètre).
create function public.log_export(p_scope text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  insert into public.audit_log (actor, action, entity, details)
    values (auth.uid(), 'export', 'requests', jsonb_build_object('scope', p_scope));
end $$;
revoke execute on function public.log_export from public, anon;
grant execute on function public.log_export to authenticated;
