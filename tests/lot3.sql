\set ON_ERROR_STOP on
\set secr '00000000-0000-0000-0000-0000000000b1'
\set ca   '00000000-0000-0000-0000-0000000000c1'
create function th2.imp(rows jsonb, force boolean default false) returns jsonb language sql as $$ select public.import_rows('test.xlsx','h1',force,rows) $$;
grant execute on function th2.imp to authenticated;
update public.profiles set active=true;
set role authenticated;
select th2.login(:'secr');
select th2.assert((th2.imp('[{"name":"HIST UN","phone":"0612345678","source_label":"Leads Dualsun","works":["VMC"],"commercial_id":"00000000-0000-0000-0000-0000000000c1","stage":"rdv_pris","rdv_on":"2026-09-18","hist_note":"Rappel 1 : x","hist_calls":"2","alerts":["test"]},{"name":"HIST DEUX","phone":"+33 6 12 34 56 78","last_result":"injoignable"}]'))->>'created' = '2', 'import de 2 lignes');
select th2.assert((select count(*) from public.activities where request_id in (select id from public.requests where import_batch_id is not null)) = 0, 'aucun appel inventé');
select th2.assert((select count(*) from public.tasks where request_id in (select id from public.requests where import_batch_id is not null)) = 0, 'aucune tâche créée');
select th2.assert((select received_on is null from public.requests where hist_calls='2'), 'date de réception inconnue conservée');
select th2.assert((select count(*) from public.assignments where reason='Reprise historique') = 1, 'attribution historique tracée');
select th2.expect_error($$select th2.imp('[{"name":"X"}]')$$, 'ALREADY_IMPORTED');
select th2.assert((th2.imp('[{"name":"X","phone":"0600000000"}]', true))->>'created' = '1', 'réimportation forcée explicite');
select th2.login(:'ca');
select th2.expect_error($$select th2.imp('[{"name":"Y"}]', true)$$, 'FORBIDDEN');
select th2.assert((select count(*) from public.requests where import_batch_id is not null) = 1, 'le commercial ne voit que son dossier historique');
select 'LOT 3 : tous les tests passent' as resultat;
