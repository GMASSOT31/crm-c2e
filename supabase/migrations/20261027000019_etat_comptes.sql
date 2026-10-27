-- Comptes : l'administrateur voit l'état réel de chaque accès (invitation non acceptée, jamais connecté, mot de passe provisoire).
-- Lecture seule : aucune donnée n'est modifiée.
create function public.admin_account_states()
returns table(id uuid, confirmed boolean, last_sign_in timestamptz, must_change boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if public.current_role_name() <> 'admin' then raise exception 'FORBIDDEN'; end if;
  return query select u.id, u.email_confirmed_at is not null, u.last_sign_in_at,
      coalesce(u.raw_user_meta_data->>'must_change_password', 'false') = 'true'
    from auth.users u join public.profiles p on p.id = u.id;
end $$;
revoke execute on function public.admin_account_states from public, anon;
grant execute on function public.admin_account_states to authenticated;
