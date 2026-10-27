\set ON_ERROR_STOP on
\set adm  '00000000-0000-0000-0000-0000000000a1'
\set secr '00000000-0000-0000-0000-0000000000b1'
\set ca   '00000000-0000-0000-0000-0000000000c1'
\set cb   '00000000-0000-0000-0000-0000000000c2'
update public.profiles set active=true;
set role authenticated;
select th2.login(:'secr');
select public.create_request('Complet Un','0670000001','c1@exemple.test',null,null,'Ville Sans Zone','99999',null,'{}',null,'2026-10-10',null);
select public.create_request('Complet Deux','0670000002','c2@exemple.test',null,null,'Ville Sans Zone','99999',null,'{}',null,'2026-10-10',null);
select public.create_request('Sans Contact',null,null,null,null,'Ville Sans Zone','99999',null,'{}',null,'2026-10-10',null);
create temp table l10 as select c.display_name n, r.id from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name in ('Complet Un','Complet Deux','Sans Contact');
grant select on l10 to authenticated;
-- un dossier déjà attribué à un commercial actif n'est pas repris ; opposition refusée
select public.assign_requests(array[(select id from l10 where n='Complet Deux')], :'cb');
select public.set_opt_out((select id from l10 where n='Complet Un'), true);
select public.create_request('Normal','0670000009','n@exemple.test',null,null,'Ville Sans Zone','99999',null,'{}',null,'2026-10-10',null);
create temp table l10b as select r.id from public.requests r join public.contacts c on c.id=r.contact_id where c.display_name='Normal';
grant select on l10b to authenticated;
select th2.assert((select jsonb_array_length(public.simulate_zones())) >= 2,'la simulation liste les dossiers non attribués');
select th2.assert((select count(*) from jsonb_array_elements(public.simulate_zones()) e where e->>'status'='incomplet') >= 1,'simulation : dossier incomplet signalé');
select th2.assert((select count(*) from public.assignments where request_id=(select id from l10b))=0,'la simulation n''écrit rien');
select public.assign_requests_report(array[(select id from l10b),(select id from l10 where n='Sans Contact'),(select id from l10 where n='Complet Deux'),(select id from l10 where n='Complet Un'),999999], :'ca') as rapport \gset
select th2.assert((:'rapport'::jsonb->>'assigned')::int=1,'un seul dossier attribué');
select th2.assert((select count(*) from jsonb_array_elements(:'rapport'::jsonb->'failed') e where e->>'reason'='INCOMPLET')=1,'échec : incomplet');
select th2.assert((select count(*) from jsonb_array_elements(:'rapport'::jsonb->'failed') e where e->>'reason'='DEJA_ATTRIBUE')=1,'échec : déjà attribué (pas de double traitement)');
select th2.assert((select count(*) from jsonb_array_elements(:'rapport'::jsonb->'failed') e where e->>'reason'='OPPOSITION')=1,'échec : opposition');
select th2.assert((select count(*) from jsonb_array_elements(:'rapport'::jsonb->'failed') e where e->>'reason'='INTROUVABLE')=1,'échec : introuvable');
select th2.assert((select assigned_to::text from public.requests where id=(select id from l10b))=:'ca','le dossier valide est attribué');
-- relancer la même opération ne change rien (idempotent)
select public.assign_requests_report(array[(select id from l10b)], :'ca') as r2 \gset
select th2.assert((:'r2'::jsonb->>'assigned')::int=0 and (:'r2'::jsonb->>'already')::int=1,'idempotent');
-- dérogation : réservée à l'administrateur, motif obligatoire, ne contourne pas l'opposition
select th2.expect_error($$select public.assign_requests_report(array[(select id from l10 where n='Sans Contact')], (select '00000000-0000-0000-0000-0000000000c1'::uuid), null, 'urgent')$$,'FORBIDDEN');
select th2.login(:'adm');
select public.assign_requests_report(array[(select id from l10 where n='Sans Contact'),(select id from l10 where n='Complet Un')], :'ca', null, 'client connu par téléphone') as r3 \gset
select th2.assert((:'r3'::jsonb->>'assigned')::int=1 and (select count(*) from jsonb_array_elements(:'r3'::jsonb->'failed') e where e->>'reason'='OPPOSITION')=1,'dérogation admin : incomplet attribué, opposition toujours refusée');
select th2.assert((select override_reason from public.assignments where request_id=(select id from l10 where n='Sans Contact'))='client connu par téléphone','dérogation tracée');
-- un commercial ne peut pas attribuer ; le dernier administrateur ne peut pas être retiré par lui-même
select th2.login(:'ca');
select th2.expect_error($$select public.assign_requests_report(array[1], (select '00000000-0000-0000-0000-0000000000c1'::uuid))$$,'FORBIDDEN');
select th2.login(:'adm');
select th2.expect_error($$select public.admin_set_active('00000000-0000-0000-0000-0000000000a1'::uuid,false)$$,'CANNOT_DEACTIVATE_SELF');
select th2.expect_error($$select public.admin_set_role('00000000-0000-0000-0000-0000000000a1'::uuid,'commercial')$$,'CANNOT_CHANGE_OWN_ROLE');
-- application des zones idempotente
select public.apply_zones() as z1 \gset
select public.apply_zones() as z2 \gset
select th2.assert((:'z2'::jsonb->>'assigned')::int=0,'apply_zones idempotent');
select 'LOT 10 : attribution en masse OK' as resultat;
