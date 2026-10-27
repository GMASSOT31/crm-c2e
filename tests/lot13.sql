\set ON_ERROR_STOP on
update public.profiles set active=true;
set role authenticated;
select th2.login('00000000-0000-0000-0000-0000000000b1');
select public.import_rows('t13.csv','h13',false,'[{"name":"Avec Date","phone":"0611223344","received_on":"2026-10-12"},{"name":"Sans Date","phone":"0611223355"},{"name":"Date Absurde Vide","phone":"0611223366","received_on":""}]'::jsonb);
select th2.assert((select received_on::text||received_precision||received_source from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name='Avec Date')='2026-10-12jourimport_fichier','date de réception du fichier conservée avec sa provenance');
select th2.assert((select received_on is null and received_precision is null from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name='Sans Date'),'sans date : aucune date inventée');
select th2.assert((select received_on is null from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name='Date Absurde Vide'),'date vide : inconnue');
select th2.expect_error($$select public.import_rows('t13.csv','h13',false,'[]'::jsonb)$$,'ALREADY_IMPORTED');
select 'LOT 13 : import avec date de réception OK' as resultat;
