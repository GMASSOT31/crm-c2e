-- Simule le schéma auth de Supabase pour tester hors Supabase.
create schema auth;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create role anon nologin; create role authenticated nologin;
grant usage on schema auth to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;
