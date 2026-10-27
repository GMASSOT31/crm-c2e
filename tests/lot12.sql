\set ON_ERROR_STOP on
\set secr '00000000-0000-0000-0000-0000000000b1'
\set ca   '00000000-0000-0000-0000-0000000000c1'
update public.profiles set active=true;
set role authenticated;
select th2.login(:'secr');
select public.create_request('Dup Premier','0690000001','dup@exemple.test',null,null,'Toulouse','31000',null,'{}',null,'2026-10-10',null);
select public.create_request('Dup Second','0690000001','dup@exemple.test',null,null,'Toulouse','31000',null,'{}',null,'2026-10-11',null);
select public.create_request('Dup Autre','0690000002','autre@exemple.test',null,null,'Toulouse','31000',null,'{}',null,'2026-10-11',null);
create temp table l12 as select c.display_name n, r.id from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name like 'Dup %';
grant select on l12 to authenticated;
-- confirmer : le second est le doublon du premier ; rien n'est supprimé, le lien et l'historique restent
select public.decide_duplicate((select id from l12 where n='Dup Second'),(select id from l12 where n='Dup Premier'),'doublon','même personne, même email');
select th2.assert((select quality::text||duplicate_of::text from public.requests where id=(select id from l12 where n='Dup Second'))='doublon'||(select id from l12 where n='Dup Premier')::text,'doublon confirmé avec lien conservé');
select th2.assert((select count(*) from public.requests where id in (select id from l12))=3,'aucune ligne supprimée');
select th2.assert((select count(*) from public.activities where request_id=(select id from l12 where n='Dup Second') and data->>'new'='doublon')=1,'décision tracée dans la chronologie');
select th2.expect_error($$select public.decide_duplicate((select id from l12 where n='Dup Premier'),(select id from l12 where n='Dup Second'),'distinct','x')$$,'ALREADY_DECIDED');
-- garder distincts : justification obligatoire
select th2.expect_error($$select public.decide_duplicate((select id from l12 where n='Dup Autre'),(select id from l12 where n='Dup Premier'),'distinct',' ')$$,'REASON_REQUIRED');
select public.decide_duplicate((select id from l12 where n='Dup Autre'),(select id from l12 where n='Dup Premier'),'distinct','Deux projets différents chez deux personnes');
select th2.assert((select quality::text from public.requests where id=(select id from l12 where n='Dup Autre'))<>'doublon','distincts : la qualité ne change pas');
-- réversible
select public.undo_duplicate((select id from l12 where n='Dup Second'),(select id from l12 where n='Dup Premier'));
select th2.assert((select quality::text from public.requests where id=(select id from l12 where n='Dup Second'))='a_verifier' and (select duplicate_of is null from public.requests where id=(select id from l12 where n='Dup Second')),'annulation : retour à « à vérifier »');
select public.decide_duplicate((select id from l12 where n='Dup Second'),(select id from l12 where n='Dup Premier'),'doublon','de nouveau');
-- droits : un commercial ne décide pas
select th2.login(:'ca');
select th2.expect_error($$select public.decide_duplicate(1,2,'doublon','x')$$,'FORBIDDEN');
select th2.expect_error($$select public.undo_duplicate(1,2)$$,'FORBIDDEN');
-- opposition : plus d'appel, de rappel ni de rendez-vous
select th2.login(:'secr');
select public.assign_requests(array[(select id from l12 where n='Dup Autre')], :'ca');
select public.set_opt_out((select id from l12 where n='Dup Autre'), true);
select th2.login(:'ca');
select th2.expect_error($$select public.record_no_answer((select id from l12 where n='Dup Autre'),null,'tok-opt')$$,'OPT_OUT');
select th2.expect_error($$select public.schedule_callback((select id from l12 where n='Dup Autre'), now()+interval '1 day')$$,'OPT_OUT');
select th2.expect_error($$select public.schedule_callback_day((select id from l12 where n='Dup Autre'), current_date+1)$$,'OPT_OUT');
select th2.expect_error($$select public.book_appointment((select id from l12 where n='Dup Autre'),'2026-11-03','10:00',false,null)$$,'OPT_OUT');
select th2.assert((select count(*) from public.activities where request_id=(select id from l12 where n='Dup Autre') and type in ('no_answer','callback','appointment'))=0,'aucune action de prospection enregistrée');
select 'LOT 12 : doublons et opposition OK' as resultat;
