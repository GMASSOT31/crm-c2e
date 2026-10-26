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
