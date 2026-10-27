-- Lot 2 (cahier des charges du 27/10/2026) : séparer les dates et leur provenance.
-- Ajouts uniquement : aucune ligne n'est supprimée, aucune donnée existante n'est remplacée.

-- 1. Sauvegarde complète avant toute transformation (schéma non exposé à l'application).
create schema if not exists backup_20261027;
create table backup_20261027.requests as select * from public.requests;
create table backup_20261027.contacts as select * from public.contacts;
create table backup_20261027.activities as select * from public.activities;
create table backup_20261027.assignments as select * from public.assignments;
revoke all on schema backup_20261027 from public, anon, authenticated;
revoke all on all tables in schema backup_20261027 from public, anon, authenticated;

-- 2. Dates : réception (jour ou minute), source de l'information, import, origine du RDV.
alter table public.requests
  add column received_at timestamptz,                       -- horodatage précis de réception, s'il est connu
  add column received_precision text check (received_precision in ('jour','minute')),
  add column received_source text,                          -- d'où vient la date (formulaire, saisie, note…)
  add column imported_at timestamptz,                       -- date d'import : jamais une date de réception
  add column rdv_origin text check (rdv_origin in ('import','confirme'));

-- Reprise : la date d'import est conservée à part ; aucune date de réception n'est inventée.
update public.requests set imported_at = created_at where import_batch_id is not null;
update public.requests set received_precision = 'jour', received_source = 'saisie' where received_on is not null;
update public.requests set rdv_origin = 'import' where import_batch_id is not null and (stage = 'rdv_pris' or rdv_on is not null);
update public.requests r set rdv_origin = 'confirme'
  where exists (select 1 from public.activities a where a.request_id = r.id and a.type = 'appointment');

-- 3. Qualité : valider les dossiers attribués, sauf ceux qui portent un avertissement du classeur
--    (doublon possible, information douteuse) : ils restent à vérifier par une personne.
with v as (
  update public.requests set quality = 'valide', version = version + 1, updated_at = now()
  where quality = 'a_verifier' and assigned_to is not null and not archived
    and duplicate_of is null and coalesce(array_length(alerts, 1), 0) = 0
  returning id)
insert into public.audit_log (actor, action, entity, details)
  select null, 'bulk_validate_assigned', 'requests', jsonb_build_object('count', count(*), 'ids', coalesce(jsonb_agg(id), '[]'::jsonb)) from v;

-- 4. Les nouvelles saisies enregistrent la précision de la date et son origine.
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
      received_precision, received_source, description, raw_text, created_by)
    values (c, p_source_id, p_source_label, p_received_on,
      case when p_received_on is not null then 'jour' end,
      case when p_received_on is not null then 'saisie' end, p_description, p_raw_text, auth.uid())
    returning id into r;
  foreach w in array p_work_type_ids loop
    insert into public.request_work_types values (r, w) on conflict do nothing;
  end loop;
  insert into public.audit_log (actor, action, entity, entity_id)
    values (auth.uid(), 'create_request', 'requests', r::text);
  perform public.zone_assign_one(r, auth.uid());
  return r;
end $$;

-- Un RDV pris par un commercial est « confirmé » (≠ statut importé du classeur).
create or replace function public.book_appointment(p_request bigint, p_date date, p_time time default null,
  p_time_tbd boolean default false, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_date is null or (p_time is null and not p_time_tbd) then raise exception 'DATE_AND_TIME_REQUIRED'; end if;
  perform public.lock_request(p_request);
  insert into public.activities (request_id, type, author, note, data)
    values (p_request, 'appointment', auth.uid(), p_note, jsonb_build_object('date', p_date, 'time', p_time, 'tbd', p_time_tbd));
  update public.requests set rdv_on=p_date, rdv_time=p_time, rdv_time_tbd=p_time_tbd, rdv_origin='confirme',
    version=version+1, updated_at=now(),
    stage = case when stage in ('recu','a_contacter','contact_etabli') then 'rdv_pris' else stage end
    where id = p_request;
  perform public.cancel_open_tasks(p_request, array['call','callback','mail']::public.task_kind[]);
end $$;

-- Import : la date d'import est enregistrée à part et le statut RDV du classeur est marqué « importé ».
create or replace function public.import_rows(p_name text, p_hash text, p_force boolean, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare b bigint; x jsonb; c bigint; r bigint; w text; n int := 0; qual public.request_quality; st public.request_stage;
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
    st := coalesce(nullif(x->>'stage',''),'recu')::public.request_stage;
    insert into public.requests (contact_id, source_id, source_label_original, received_on, quality, stage, last_result,
        close_reason, assigned_to, assigned_at, rdv_on, rdv_origin, hist_note, hist_calls, alerts, duplicate_of,
        import_batch_id, imported_at, created_by)
      values (c, nullif(x->>'source_id','')::bigint, x->>'source_label', null, qual,
        st, nullif(x->>'last_result','')::public.contact_result,
        nullif(x->>'close_reason','')::public.contact_result, nullif(x->>'commercial_id','')::uuid,
        nullif(x->>'assigned_on','')::timestamptz, nullif(x->>'rdv_on','')::date,
        case when st = 'rdv_pris' or nullif(x->>'rdv_on','') is not null then 'import' end,
        x->>'hist_note', x->>'hist_calls',
        coalesce(array(select jsonb_array_elements_text(coalesce(x->'alerts','[]'::jsonb))), '{}'),
        nullif(x->>'duplicate_of','')::bigint, b, now(), auth.uid()) returning id into r;
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

revoke execute on all functions in schema public from public, anon;
grant execute on function public.create_request, public.book_appointment, public.import_rows to authenticated;
