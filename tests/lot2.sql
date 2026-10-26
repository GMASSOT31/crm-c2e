\set ON_ERROR_STOP on
\set secr '00000000-0000-0000-0000-0000000000b1'
\set adm  '00000000-0000-0000-0000-0000000000a1'
\set ca   '00000000-0000-0000-0000-0000000000c1'
\set cb   '00000000-0000-0000-0000-0000000000c2'
create schema th2; grant usage on schema th2 to authenticated;
create function th2.login(u text) returns void language plpgsql as $$ begin perform set_config('request.jwt.claim.sub', u, false); end $$;
create function th2.assert(ok boolean, label text) returns void language plpgsql as $$ begin if not ok then raise exception 'FAIL: %', label; end if; end $$;
create function th2.expect_error(q text, msg text) returns void language plpgsql as $$
begin begin execute q; exception when others then
  if sqlerrm like '%'||msg||'%' then return; end if; raise exception 'FAIL: erreur inattendue "%" pour %', sqlerrm, q; end;
  raise exception 'FAIL: aucune erreur pour % (attendu %)', q, msg; end $$;
grant execute on all functions in schema th2 to authenticated;
-- jeu de données (en tant que propriétaire, hors RLS)
select th2.login(:'secr');
insert into public.contacts (display_name, phone_raw, phone_norm, email_raw, email_norm) values
 ('Avec Mail','0611111111','0611111111','ok@exemple.test','ok@exemple.test'),
 ('Sans Mail','0622222222','0622222222',null,null),
 ('Autre Dossier','0633333333','0633333333','x@exemple.test','x@exemple.test');
insert into public.requests (contact_id, quality) select id,'valide' from public.contacts where display_name in ('Avec Mail','Sans Mail','Autre Dossier');
create temp table rq as select (select r.id from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name='Avec Mail') a,
 (select r.id from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name='Sans Mail') b,
 (select r.id from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name='Autre Dossier') o;
grant select on rq to authenticated;
update public.profiles set active = true;
set role authenticated;
select public.assign_requests(array[(select a from rq),(select b from rq)], :'ca'::uuid);
select public.assign_requests(array[(select o from rq)], :'cb'::uuid);

select th2.login(:'ca');
-- T08 : compteurs 1, 2, 3 et une seule tâche mail
select th2.assert((select consecutive from public.record_no_answer((select a from rq))) = 1, 'compteur 1');
select th2.assert((select consecutive from public.record_no_answer((select a from rq))) = 2, 'compteur 2');
select th2.assert((select mail_task_created from public.record_no_answer((select a from rq))) , '3e appel : tâche mail créée');
select th2.assert((select count(*) from public.tasks where request_id=(select a from rq) and kind='mail') = 1, 'une seule tâche mail');
select th2.assert((select mail_task_created from public.record_no_answer((select a from rq))) = false, '4e appel : pas de nouvelle tâche');
select th2.assert((select count(*) from public.tasks where request_id=(select a from rq) and kind='mail') = 1, 'toujours une seule tâche mail');
select th2.assert((select stage from public.requests where id=(select a from rq)) = 'a_contacter', 'la 3e tentative ne clôture pas');
-- T09 : double clic (même jeton) = un seul appel
select th2.login(:'ca');
select * from public.record_no_answer((select b from rq), null, 'tok-1');
select * from public.record_no_answer((select b from rq), null, 'tok-1');
select th2.assert((select total from public.call_counters((select b from rq))) = 1, 'double clic : 1 appel');
-- T11 : email absent => relance bloquée, traitement par téléphone toujours possible
select * from public.record_no_answer((select b from rq));
select * from public.record_no_answer((select b from rq));
select th2.assert(public.mail_block_reason((select b from rq)) = 'Email manquant ou à corriger', 'email absent signalé');
select th2.assert(public.mail_block_reason((select a from rq)) is null, 'email valide : relance autorisée');
-- T10 : contact établi interrompt la séquence et annule la tâche mail ; compteur consécutif remis à 0, total conservé
select public.record_contact((select a from rq));
select th2.assert((select count(*) from public.tasks where request_id=(select a from rq) and kind='mail' and status='open') = 0, 'tâche mail annulée');
select th2.assert((select consecutive from public.call_counters((select a from rq))) = 0 and (select total from public.call_counters((select a from rq))) = 4, 'consécutifs 0, total 4');
-- nouvelle séquence => nouvelle tâche mail possible
select * from public.record_no_answer((select a from rq)); select * from public.record_no_answer((select a from rq));
select th2.assert((select mail_task_created from public.record_no_answer((select a from rq))), 'nouvelle séquence : nouvelle tâche mail');
-- T13 : devis puis appel sans réponse conserve l'étape
select public.record_quote((select a from rq), 'D-001');
select * from public.record_no_answer((select a from rq));
select th2.assert((select stage from public.requests where id=(select a from rq)) = 'devis_realise', 'étape Devis réalisé conservée');
-- Règles de saisie
select th2.expect_error(format('select public.schedule_callback(%s, null)', (select a from rq)), 'DUE_REQUIRED');
select th2.expect_error(format('select public.book_appointment(%s, current_date)', (select a from rq)), 'DATE_AND_TIME_REQUIRED');
select public.book_appointment((select a from rq), current_date + 3, null, true);
select th2.expect_error(format('select public.record_sale(%s, null)', (select a from rq)), 'SALE_DATE_REQUIRED');
select th2.expect_error(format('select public.record_sale(%s, current_date, 5000)', (select a from rq)), 'VAT_MODE_REQUIRED');
select public.record_sale((select a from rq), current_date);
select th2.assert((select stage from public.requests where id=(select a from rq)) = 'vente_faite', 'vente sans montant acceptée');
-- T17 clôture annule les relances et bloque la suite ; opposition bloque la relance
select public.close_request((select b from rq), 'trop_loin');
select th2.assert((select count(*) from public.tasks where request_id=(select b from rq) and status='open') = 0, 'clôture : aucune tâche ouverte');
select th2.assert(public.mail_block_reason((select b from rq)) = 'Dossier clôturé', 'clôturé : mail bloqué');
select th2.expect_error(format('select * from public.record_no_answer(%s)', (select b from rq)), 'REQUEST_CLOSED');
select th2.expect_error(format('select public.reopen_request(%s, ''x'')', (select b from rq)), 'FORBIDDEN');
-- T01 : A ne peut agir sur le dossier de B ni lire ses activités
select th2.expect_error(format('select * from public.record_no_answer(%s)', (select o from rq)), 'FORBIDDEN');
select th2.assert((select count(*) from public.activities where request_id=(select o from rq)) = 0, 'activités de B invisibles pour A');
-- Réouverture par l'administrateur avec motif
select th2.login(:'adm');
select th2.expect_error(format('select public.reopen_request(%s, '' '')', (select b from rq)), 'REASON_REQUIRED');
select public.reopen_request((select b from rq), 'client rappelé');
select th2.assert((select stage from public.requests where id=(select b from rq)) = 'a_contacter', 'réouverture');
select th2.assert((select count(*) from public.activities where request_id=(select b from rq) and type='close') = 1, 'historique intact après réouverture');
select th2.login(:'secr');
select public.set_opt_out((select b from rq), true);
select th2.assert(public.mail_block_reason((select b from rq)) = 'Opposition au contact enregistrée', 'opposition bloque le mail');
select 'LOT 2 : tous les tests passent' as resultat;
