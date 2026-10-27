\set ON_ERROR_STOP on
\set secr '00000000-0000-0000-0000-0000000000b1'
\set ca   '00000000-0000-0000-0000-0000000000c1'
\set cb   '00000000-0000-0000-0000-0000000000c2'
update public.profiles set active=true;
set role authenticated;
select th2.login(:'secr');
select public.create_request('Devis Test','0695000001','dv@exemple.test',null,null,'Toulouse','31000',null,'{}',null,'2026-10-10',null);
create temp table l14 as select r.id from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name='Devis Test';
grant select on l14 to authenticated;
select public.assign_requests(array[(select id from l14)], :'ca');
select th2.login(:'ca');
-- devis réalisé avec référence et relance en une opération
select public.record_quote_followup((select id from l14),'D-2026-77', now() + interval '5 days');
select th2.assert((select quote_ref||stage::text from public.requests where id=(select id from l14))='D-2026-77devis_realise','devis réalisé avec sa référence');
select th2.assert((select count(*) from public.tasks where request_id=(select id from l14) and kind='quote_followup' and status='open')=1,'une relance de devis ouverte');
-- une seule relance ouverte à la fois
select public.schedule_quote_followup((select id from l14), now() + interval '9 days');
select th2.assert((select count(*) from public.tasks where request_id=(select id from l14) and kind='quote_followup' and status='open')=1,'reprogrammer ne crée pas une deuxième relance');
select th2.expect_error($$select public.schedule_quote_followup((select id from l14), null)$$,'DUE_REQUIRED');
-- annulation : motif obligatoire, tracée
create temp table tk14 as select id from public.tasks where request_id=(select id from l14) and status='open';
grant select on tk14 to authenticated;
select th2.expect_error($$select public.cancel_task((select id from tk14),' ')$$,'REASON_REQUIRED');
select public.cancel_task((select id from tk14),'Client a déjà signé ailleurs');
select th2.assert((select status::text from public.tasks where id=(select id from tk14))='cancelled','action annulée (pas supprimée)');
select th2.expect_error($$select public.cancel_task((select id from tk14),'encore')$$,'TASK_NOT_OPEN');
select th2.assert((select count(*) from public.activities where request_id=(select id from l14) and data->>'kind'='task_cancel')=1,'annulation tracée avec son motif');
-- absence de suite justifiée ; effacer la justification
select public.set_no_next_action((select id from l14),'Attend la décision du conseil syndical');
select th2.assert((select no_next_reason from public.requests where id=(select id from l14))='Attend la décision du conseil syndical','absence de suite justifiée');
select public.set_no_next_action((select id from l14),'');
select th2.assert((select no_next_reason is null from public.requests where id=(select id from l14)),'justification effacée');
-- vente puis correction : une seule vente, jamais comptée deux fois
select public.record_sale((select id from l14),'2026-10-20',12000,'HT');
select public.record_sale((select id from l14),'2026-10-21',0,'HT');
select th2.assert((select sale_amount=0 and sale_on='2026-10-21' from public.requests where id=(select id from l14)),'correction de la vente : montant nul explicite');
select th2.assert((select count(*) from public.requests where stage='vente_faite' and id=(select id from l14))=1,'une seule vente pour le dossier');
-- droits
select th2.login(:'cb');
select th2.expect_error($$select public.set_no_next_action((select id from l14),'x')$$,'FORBIDDEN');
select th2.expect_error($$select public.schedule_quote_followup((select id from l14), now())$$,'FORBIDDEN');
select 'LOT 14 : devis, relances et ventes OK' as resultat;
