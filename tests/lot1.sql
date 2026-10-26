\set ON_ERROR_STOP on
-- Chaque contrôle lève une erreur s'il échoue.
create schema th; grant usage on schema th to authenticated;
create function th.login(u text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', u, false); end $$;
create function th.expect_error(q text, msg text) returns void language plpgsql as $$
begin
  begin execute q; exception when others then
    if sqlerrm like '%' || msg || '%' then return; end if;
    raise exception 'FAIL: erreur inattendue "%" pour %', sqlerrm, q;
  end;
  raise exception 'FAIL: aucune erreur pour % (attendu %)', q, msg;
end $$;
create function th.assert(ok boolean, label text) returns void language plpgsql as $$
begin if not ok then raise exception 'FAIL: %', label; end if; end $$;

\set secr '00000000-0000-0000-0000-0000000000b1'
\set adm  '00000000-0000-0000-0000-0000000000a1'
\set ca   '00000000-0000-0000-0000-0000000000c1'
\set cb   '00000000-0000-0000-0000-0000000000c2'

-- Normalisation des téléphones (T06)
select th.assert(public.normalize_phone('06 13 51 80 72') = public.normalize_phone('+33 6 13 51 80 72'), 'tel 06 = +33');
select th.assert(public.normalize_phone('0033613518072') = '0613518072', 'tel 0033');
select th.assert(public.normalize_phone('+32 475 12 34 56') = '+32475123456', 'préfixe étranger conservé');

grant execute on all functions in schema th to authenticated;
set role authenticated;

-- Secrétariat crée 2 demandes et attribue la première à A
select th.login(:'secr');
create temp table ids as select
  public.create_request('Dupont Test','06 11 22 33 44','dupont@exemple.test',1,'Leads Dualsun','Toulouse','31000') as r1,
  public.create_request('Martin Test','+33 7 55 44 33 22',null,2,null,'Blagnac') as r2,
  public.create_request(null,null,null,1) as r3_incomplet;
grant select on ids to authenticated;
select th.assert(public.assign_requests(array[(select r1 from ids)], :'ca'::uuid) = 1, 'attribution à A');
select th.assert((select stage from public.requests where id=(select r1 from ids)) = 'a_contacter', 'étape passe à contacter');

-- Dossier incomplet refusé, dérogation réservée à l'admin (T07 / validation minimale)
select th.expect_error(format('select public.assign_requests(array[%s], %L::uuid)', (select r3_incomplet from ids), :'ca'), 'INCOMPLETE_CONTACT');
select th.expect_error(format('select public.assign_requests(array[%s], %L::uuid, null, ''motif'')', (select r3_incomplet from ids), :'ca'), 'INCOMPLETE_CONTACT');
select th.login(:'adm');
select th.assert(public.assign_requests(array[(select r3_incomplet from ids)], :'cb'::uuid, null, 'dérogation admin') = 1, 'dérogation admin');
select th.login(:'secr');
select public.assign_requests(array[(select r2 from ids)], :'cb'::uuid);

-- T01 confidentialité : A ne voit que ses dossiers
select th.login(:'ca');
select th.assert((select count(*) from public.requests) = 1, 'A voit 1 dossier');
select th.assert((select count(*) from public.contacts) = 1, 'A voit 1 contact');
select th.assert((select count(*) from public.requests where id in (select r2 from ids)) = 0, 'A ne voit pas le dossier de B (URL directe)');
select th.expect_error(format('select public.update_contact_info(%s, 1, ''{"city":"Hack"}'')', (select r2 from ids)), 'FORBIDDEN');
select th.expect_error('update public.requests set assigned_to = null', 'permission denied');
select th.expect_error('select public.assign_requests(array[1], null)', 'FORBIDDEN');
select th.expect_error(format('select public.admin_set_role(%L::uuid, ''admin'')', :'ca'), 'FORBIDDEN');
select th.assert((select count(*) from public.audit_log) = 0, 'A ne lit pas le journal');
select th.assert((select count(*) from public.profiles) = 1, 'A ne voit que son profil');

-- Modification de ses coordonnées + conflit de version
select th.assert(public.update_contact_info((select r1 from ids), 2, '{"city":"Colomiers","phone_raw":"07 00 00 00 01"}') = 3, 'MAJ coordonnées version 3');
select th.assert((select phone_norm from public.contacts limit 1) = '0700000001', 'tel renormalisé');
select th.expect_error(format('select public.update_contact_info(%s, 2, ''{"city":"X"}'')', (select r1 from ids)), 'CONFLICT');
select th.expect_error(format('select public.update_contact_info(%s, 3, ''{"id":5}'')', (select r1 from ids)), 'FIELD_NOT_ALLOWED');

-- T07 réattribution A -> B : tracée, A perd l'accès
select th.login(:'secr');
select public.assign_requests(array[(select r1 from ids)], :'cb'::uuid, 'équilibrage');
select th.assert((select count(*) from public.assignments where request_id=(select r1 from ids)) = 2, 'historique 2 lignes');
select th.login(:'ca');
select th.assert((select count(*) from public.requests) = 0, 'A perd l''accès après réattribution');
select th.assert((select count(*) from public.contacts) = 0, 'A perd l''accès au contact');
select th.login(:'cb');
select th.assert((select count(*) from public.requests) = 3, 'B a 3 dossiers');

-- Cible invalide et désactivation
select th.login(:'adm');
select public.admin_set_active(:'cb'::uuid, false);
select th.assert((select count(*) from public.requests_to_reassign) = 3, 'file à réattribuer = 3');
select th.expect_error(format('select public.assign_requests(array[%s], %L::uuid)', (select r1 from ids), :'cb'), 'TARGET_NOT_ACTIVE_SALESPERSON');
select th.expect_error(format('select public.admin_set_active(%L::uuid, false)', :'adm'), 'CANNOT_DEACTIVATE_SELF');
select th.login(:'cb');
select th.assert((select count(*) from public.requests) = 0, 'B désactivé : accès coupé immédiatement');
select th.login(:'adm');
select th.assert((select count(*) from public.assignments) >= 4, 'historique conservé');
select th.assert((select count(*) from public.audit_log where action='set_active') = 1, 'désactivation journalisée');

-- Secrétariat ne gère pas les comptes
select th.login(:'secr');
select th.expect_error(format('select public.admin_set_role(%L::uuid, ''admin'')', :'ca'), 'FORBIDDEN');
select 'LOT 1 : tous les tests passent' as resultat;
