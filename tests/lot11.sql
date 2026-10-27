\set ON_ERROR_STOP on
\set adm  '00000000-0000-0000-0000-0000000000a1'
\set secr '00000000-0000-0000-0000-0000000000b1'
\set ca   '00000000-0000-0000-0000-0000000000c1'
\set cb   '00000000-0000-0000-0000-0000000000c2'
update public.profiles set active=true;
set role authenticated;
-- FIA01 : droits effectifs (pas seulement la visibilité des menus)
select th2.login(:'secr');
select public.create_request('Isolation Test','0680000001','iso@exemple.test',null,null,'Toulouse','31000',null,'{}',null,'2026-10-10',null);
create temp table l11 as select r.id from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name='Isolation Test';
grant select on l11 to authenticated;
select public.assign_requests(array[(select id from l11)], :'ca');
select th2.login(:'ca');
select public.record_no_answer((select id from l11), null, 'tok-l11');
select public.add_note((select id from l11),'Note de A');
select th2.login(:'cb');
select th2.assert((select count(*) from public.requests where id=(select id from l11))=0,'B ne voit pas le dossier de A (changer l''identifiant ne sert à rien)');
select th2.assert((select count(*) from public.activities where request_id=(select id from l11))=0,'B ne voit pas les activités de A');
select th2.assert((select count(*) from public.tasks where request_id=(select id from l11))=0,'B ne voit pas les tâches de A');
select th2.assert((select count(*) from public.contacts c join public.requests r on r.contact_id=c.id where r.id=(select id from l11))=0,'B ne voit pas le contact de A');
select th2.expect_error($$select public.record_no_answer((select id from l11),null,'tok-x')$$,'FORBIDDEN');
select th2.expect_error($$select public.book_appointment((select id from l11),'2026-11-03','10:00',false,null)$$,'FORBIDDEN');
select th2.expect_error($$select public.close_request((select id from l11),'pas_interesse',null)$$,'FORBIDDEN');
select th2.expect_error($$select public.set_quality((select id from l11),'spam')$$,'FORBIDDEN');
select th2.expect_error($$select public.simulate_zones()$$,'FORBIDDEN');
select th2.expect_error($$select public.apply_zones()$$,'FORBIDDEN');
select th2.expect_error($$select public.admin_set_role('00000000-0000-0000-0000-0000000000c2'::uuid,'admin')$$,'FORBIDDEN');
select th2.expect_error($$select public.import_rows('x.xlsx','hh',false,'[]'::jsonb)$$,'FORBIDDEN');
-- aucune écriture directe pour un utilisateur connecté
select th2.expect_error($$update public.requests set stage='vente_faite'$$,'permission denied');
select th2.expect_error($$insert into public.activities (request_id,type) values (1,'note')$$,'permission denied');
-- un double clic (même jeton) ne crée qu'un seul appel sans réponse
select th2.login(:'ca');
select public.record_no_answer((select id from l11), null, 'tok-l11');
select th2.assert((select count(*) from public.activities where request_id=(select id from l11) and type='no_answer')=1,'double clic : un seul appel enregistré');
-- l'administrateur et le secrétariat voient tout, le commercial désactivé perd l'accès
select th2.login(:'adm');
select th2.assert((select count(*) from public.requests where id=(select id from l11))=1,'l''administrateur voit tout');
reset role;
update public.profiles set active=false where id=:'ca';
set role authenticated;
select th2.login(:'ca');
select th2.assert((select count(*) from public.requests where id=(select id from l11))=0,'un compte désactivé ne voit plus rien');
select th2.assert((select count(*) from public.activities where request_id=(select id from l11) and type='note')=0 ,'… ni ses activités');
reset role;
select th2.assert((select count(*) from public.activities where request_id=(select id from l11) and type='no_answer')=1,'l''historique est conservé après désactivation');
update public.profiles set active=true where id=:'ca';
select 'LOT 11 : droits et isolation OK' as resultat;
