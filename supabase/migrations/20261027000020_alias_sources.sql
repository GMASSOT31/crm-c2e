-- DAT03 : sources = identifiants stables avec libellé court ; une variante peut être l'alias d'une source principale
-- (statistiques et filtres regroupent), sans jamais effacer le libellé d'origine des dossiers. Ajouts uniquement.
alter table public.sources
  add column short_name text,
  add column alias_of bigint references public.sources(id),
  add check (alias_of is null or alias_of <> id);

-- Rapprocher une variante d'une source principale (administrateur). p_canonical null = retirer l'alias.
create function public.set_source_alias(p_source bigint, p_canonical bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare old bigint;
begin
  if public.current_role_name() <> 'admin' then raise exception 'FORBIDDEN'; end if;
  select alias_of into old from public.sources where id = p_source for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_canonical is not null then
    if p_canonical = p_source then raise exception 'BAD_ALIAS'; end if;
    if not exists (select 1 from public.sources where id = p_canonical and alias_of is null) then raise exception 'BAD_ALIAS'; end if;
    if exists (select 1 from public.sources where alias_of = p_source) then raise exception 'HAS_ALIASES'; end if;
  end if;
  update public.sources set alias_of = p_canonical where id = p_source;
  insert into public.audit_log (actor, action, entity, entity_id, details)
    values (auth.uid(), 'set_source_alias', 'sources', p_source::text, jsonb_build_object('old', old, 'new', p_canonical));
end $$;

create function public.set_source_short_name(p_source bigint, p_short text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if public.current_role_name() <> 'admin' then raise exception 'FORBIDDEN'; end if;
  if length(coalesce(p_short, '')) > 40 then raise exception 'BAD_ALIAS'; end if;
  update public.sources set short_name = nullif(btrim(p_short), '') where id = p_source;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.set_source_alias, public.set_source_short_name to authenticated;
