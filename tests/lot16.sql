\set ON_ERROR_STOP on
\set adm  '00000000-0000-0000-0000-0000000000a1'
\set secr '00000000-0000-0000-0000-0000000000b1'
update public.profiles set active=true;
-- état des comptes : invitation non acceptée, mot de passe provisoire à changer
update auth.users set email_confirmed_at = now(), last_sign_in_at = now() where id = :'adm';
update auth.users set email_confirmed_at = null, last_sign_in_at = null, raw_user_meta_data = '{"must_change_password": true}' where id = :'secr';
set role authenticated;
select th2.login(:'adm');
select th2.assert((select not confirmed and last_sign_in is null and must_change from public.admin_account_states() where id=:'secr'),'invitation non acceptée repérée');
select th2.assert((select confirmed and last_sign_in is not null and not must_change from public.admin_account_states() where id=:'adm'),'compte actif repéré');
select th2.login(:'secr');
select th2.expect_error($$select * from public.admin_account_states()$$,'FORBIDDEN');
select 'LOT 16 : état des comptes OK' as resultat;
