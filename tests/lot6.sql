\set ON_ERROR_STOP on
\set secr '00000000-0000-0000-0000-0000000000b1'
\set ca   '00000000-0000-0000-0000-0000000000c1'
update public.profiles set active=true;
set role authenticated;
select th2.login(:'secr');
create temp table w as select public.create_request('Mobile Test','0611000201',null,1) a, public.create_request('Mobile Test B','0611000202',null,1) b;
grant select on w to authenticated;
select public.assign_requests(array[(select a from w),(select b from w)], :'ca'::uuid);
select th2.login(:'ca');
-- 2 appels sans réponse puis RDV pris : la séquence est interrompue, aucune tâche mail
select * from public.record_no_answer((select a from w));
select * from public.record_no_answer((select a from w));
select public.book_appointment((select a from w), current_date + 2, '10:00'::time);
select th2.assert((select consecutive from public.call_counters((select a from w))) = 0, 'RDV pris remet le compteur consécutif à 0');
select th2.assert((select total from public.call_counters((select a from w))) = 2, 'total historique conservé');
-- 3e appel après RDV : nouvelle séquence, pas de tâche mail avant 3 nouveaux appels
select * from public.record_no_answer((select a from w));
select th2.assert((select count(*) from public.tasks where request_id=(select a from w) and kind='mail') = 0, 'pas de mail après RDV + 1 appel');
-- Devis à faire
select public.mark_quote_todo((select b from w), 'client demande un chiffrage');
select th2.assert((select stage from public.requests where id=(select b from w)) = 'devis_a_faire', 'étape Devis à faire');
select th2.assert((select count(*) from public.tasks where request_id=(select b from w) and kind='quote' and status='open') = 1, 'tâche devis créée');
select public.mark_quote_todo((select b from w));
select th2.assert((select count(*) from public.tasks where request_id=(select b from w) and kind='quote' and status='open') = 1, 'une seule tâche devis ouverte');
select public.record_quote((select b from w), 'D-42');
select th2.assert((select stage from public.requests where id=(select b from w)) = 'devis_realise', 'devis réalisé');
select th2.assert((select count(*) from public.tasks where request_id=(select b from w) and kind='quote' and status='open') = 0, 'tâche devis fermée');
select public.mark_quote_todo((select b from w));
select th2.assert((select stage from public.requests where id=(select b from w)) = 'devis_realise', 'pas de retour en arrière depuis devis réalisé');
select th2.login('00000000-0000-0000-0000-0000000000c2');
select th2.expect_error(format('select public.mark_quote_todo(%s)', (select a from w)), 'FORBIDDEN');
select 'LOT 6 : devis à faire et RDV OK' as resultat;
