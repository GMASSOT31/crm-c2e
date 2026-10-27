\set ON_ERROR_STOP on
\set secr '00000000-0000-0000-0000-0000000000b1'
\set ca   '00000000-0000-0000-0000-0000000000c1'
update public.profiles set active=true;
set role authenticated;
select th2.login(:'secr');
-- date de réception connue au jour : précision enregistrée ; inconnue : aucune date inventée
select public.create_request('Test Datée','0640000001','d1@exemple.test',null,null,'Toulouse','31000',null,'{}',null,'2026-10-10',null);
select public.create_request('Test Sans Date','0640000002','d2@exemple.test',null,null,'Toulouse','31000',null,'{}',null,null,null);
select th2.assert((select received_precision from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name='Test Datée')='jour','précision au jour');
select th2.assert((select received_on is null and received_at is null and received_precision is null and imported_at is null from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name='Test Sans Date'),'date inconnue reste inconnue');
-- import : la date d'import est à part, le RDV du classeur est « importé », aucune date de réception n'est créée
select public.import_rows('t8.xlsx','h8',false,'[{"name":"Import RDV","phone":"0650000001","stage":"rdv_pris"},{"name":"Import Simple","phone":"0650000002"}]'::jsonb);
select th2.assert((select imported_at is not null and received_on is null and rdv_origin='import' from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name='Import RDV'),'import : date d''import séparée, RDV importé');
select th2.assert((select rdv_origin is null from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name='Import Simple'),'pas de RDV déduit sans statut');
-- un RDV pris par un commercial est « confirmé »
select public.assign_requests(array[(select r.id from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name='Test Datée')], :'ca');
select th2.login(:'ca');
select public.book_appointment((select r.id from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name='Test Datée'),'2026-11-03','10:00',false,null);
select th2.assert((select rdv_origin from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name='Test Datée')='confirme','RDV confirmé');
-- le schéma de sauvegarde existe et n'est pas lisible par un utilisateur
reset role;
select th2.assert((select count(*) from information_schema.tables where table_schema='backup_20261027')=4,'sauvegarde : 4 tables');
set role authenticated;
select th2.expect_error($$select * from backup_20261027.requests$$,'permission denied');
select 'LOT 8 : dates et provenance OK' as resultat;
