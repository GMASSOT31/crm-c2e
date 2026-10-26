-- Lot 3 : reprise historique (Excel/CSV). Aucun appel, tâche, message ni notification n'est créé.
create table public.import_batches (
  id bigint generated always as identity primary key,
  file_hash text not null,
  file_name text,
  created_by uuid references public.profiles(id),
  at timestamptz not null default now(),
  row_count integer not null default 0
);
create index on public.import_batches (file_hash);
alter table public.import_batches enable row level security;
create policy batches_read on public.import_batches for select to authenticated using (public.is_staff());
revoke all on public.import_batches from anon, authenticated;
grant select on public.import_batches to authenticated;

alter table public.requests
  add column import_batch_id bigint references public.import_batches(id),
  add column hist_note text,
  add column hist_calls text,
  add column alerts text[] not null default '{}',
  add column duplicate_of bigint references public.requests(id);

-- p_rows : tableau JSON d'objets {name, phone, email, address, source_id, source_label, works[], commercial_id,
--   assigned_on, stage, last_result, close_reason, rdv_on, hist_note, hist_calls, alerts[], duplicate_of}
create function public.import_rows(p_name text, p_hash text, p_force boolean, p_rows jsonb)
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
    insert into public.contacts (display_name, phone_raw, phone_norm, email_raw, email_norm, address, created_by)
      values (nullif(btrim(x->>'name'),''), x->>'phone', public.normalize_phone(x->>'phone'), x->>'email',
        public.normalize_email(x->>'email'), x->>'address', auth.uid()) returning id into c;
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

create function public.batch_exists(p_hash text) returns timestamptz
language sql stable security definer set search_path = '' as $$
  select max(at) from public.import_batches where file_hash = p_hash and public.is_staff()
$$;

revoke execute on function public.import_rows, public.batch_exists from public, anon;
grant execute on function public.import_rows, public.batch_exists to authenticated;
