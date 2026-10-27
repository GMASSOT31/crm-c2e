\set ON_ERROR_STOP on
\set secr '00000000-0000-0000-0000-0000000000b1'
\set ca   '00000000-0000-0000-0000-0000000000c1'
\set cb   '00000000-0000-0000-0000-0000000000c2'
update public.profiles set active=true;
set role authenticated;
select th2.login(:'secr');
select public.create_request('Lot9 Dossier','0660000001','l9@exemple.test',null,null,'Toulouse','31000',null,'{}',null,'2026-10-10',null);
create temp table l9 as select r.id from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name='Lot9 Dossier';
grant select on l9 to authenticated;
select public.assign_requests(array[(select id from l9)], :'ca');
select public.set_quality((select id from l9),'valide');
select th2.assert((select count(*) from public.activities where request_id=(select id from l9) and data->>'kind'='change' and data->>'old'='a_verifier' and data->>'new'='valide')=1,'changement de qualité journalisé (ancienne et nouvelle valeur)');
select th2.login(:'ca');
-- note libre : signée, datée, ne change ni étape ni compteurs
create temp table st0 as select stage::text s from public.requests where id=(select id from l9);
grant select on st0 to authenticated;
select public.add_note((select id from l9),'Client rappelle jeudi');
select th2.assert((select author::text from public.activities where request_id=(select id from l9) and type='note' and data->>'kind'='free')=:'ca','note signée par son auteur');
select th2.assert((select stage::text from public.requests where id=(select id from l9))=(select s from st0),'une note ne change pas l''étape');
select th2.assert((select total from public.call_counters((select id from l9)))=0,'une note n''est pas un appel');
select th2.expect_error($$select public.add_note((select id from l9),' ')$$,'NOTE_REQUIRED');
select th2.login(:'cb');
select th2.expect_error($$select public.add_note((select id from l9),'intrus')$$,'FORBIDDEN');
-- RDV : sans RDV, pas de statut ; annulé exige une suite ; l'ancienne date reste dans l'historique
select th2.login(:'ca');
select th2.expect_error($$select public.set_rdv_status((select id from l9),'realise')$$,'NO_APPOINTMENT');
select public.book_appointment((select id from l9),'2026-11-03','10:00',false,null);
select th2.assert((select rdv_status from public.requests where id=(select id from l9))='planifie','RDV planifié');
select th2.expect_error($$select public.set_rdv_status((select id from l9),'annule')$$,'NEXT_ACTION_REQUIRED');
select public.book_appointment((select id from l9),'2026-11-10','14:00',false,'reporté');
select th2.assert((select count(*) from public.activities where request_id=(select id from l9) and type='appointment')=2,'le report conserve l''ancienne date');
select public.set_rdv_status((select id from l9),'annule','Client indisponible', now() + interval '2 days');
select th2.assert((select rdv_status||stage::text from public.requests where id=(select id from l9))='annulecontact_etabli','annulation : suite demandée, étape revue');
select th2.assert((select count(*) from public.tasks where request_id=(select id from l9) and kind='callback' and status='open')=1,'rappel créé après annulation');
select th2.assert((select count(*) from public.activities where request_id=(select id from l9) and type='appointment')=2,'historique des RDV non supprimé');
-- prochaines actions : terminer explicitement, reprogrammer ; journée sans heure
select public.complete_task((select id from public.tasks where request_id=(select id from l9) and status='open' limit 1));
select th2.assert((select count(*) from public.tasks where request_id=(select id from l9) and status='open')=0,'tâche terminée : plus d''échéance ouverte');
select th2.expect_error($$select public.complete_task((select id from public.tasks where request_id=(select id from l9) order by id desc limit 1))$$,'TASK_NOT_OPEN');
select public.schedule_callback_day((select id from l9),'2026-11-05');
select th2.assert((select all_day and due_at = timestamptz '2026-11-05 23:00:00+00' from public.tasks where request_id=(select id from l9) and status='open'),'journée sans heure : échéance à minuit (Paris) le jour suivant');
select public.reschedule_task((select id from public.tasks where request_id=(select id from l9) and status='open'), now() + interval '3 days');
select th2.assert((select not all_day from public.tasks where request_id=(select id from l9) and status='open'),'reprogrammation : heure précise');
select th2.assert((select count(*) from public.activities where request_id=(select id from l9) and data->>'kind' in ('task_done','task_resched'))=2,'terminer / reprogrammer tracés');
create temp table tk as select id from public.tasks where request_id=(select id from l9) and status='open';
grant select on tk to authenticated;
select th2.login(:'cb');
select th2.expect_error($$select public.complete_task((select id from tk))$$,'FORBIDDEN');
select 'LOT 9 : notes, rendez-vous, actions OK' as resultat;
