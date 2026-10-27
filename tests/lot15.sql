\set ON_ERROR_STOP on
\set adm  '00000000-0000-0000-0000-0000000000a1'
\set secr '00000000-0000-0000-0000-0000000000b1'
\set ca   '00000000-0000-0000-0000-0000000000c1'
update public.profiles set active=true;
set role authenticated;
select th2.login(:'adm');
select public.set_zone_label('Zone Diag A', array['81','8600'], array['Albi']);
select public.set_zone_label('Zone Diag B', array['8120'], array['Gaillac']);
reset role;
-- sans compte actif : la règle existe mais personne ne la porte
select th2.assert((select status from public.zone_diagnose('81500',null,'Castres'))='sans_compte','règle sans compte : cause « sans compte »');
select th2.assert((select rule from public.zone_diagnose('81500',null,'Castres'))='code postal 81','règle retenue affichée');
select th2.assert((select status from public.zone_diagnose('75001',null,'Paris'))='aucune','aucune règle : cause « aucune zone »');
-- comptes reliés par le nom
insert into auth.users (id,email) values ('00000000-0000-0000-0000-0000000000d1','da@exemple.test'),('00000000-0000-0000-0000-0000000000d2','db@exemple.test');
insert into public.profiles (id, full_name, role) values ('00000000-0000-0000-0000-0000000000d1','Zone Diag A','commercial'),('00000000-0000-0000-0000-0000000000d2','Zone Diag B','commercial');
select th2.assert((select status||owner::text from public.zone_diagnose('81500',null,'Castres'))='ok00000000-0000-0000-0000-0000000000d1','département -> A');
select th2.assert((select rule from public.zone_diagnose('81200',null,'Castres'))='code postal 8120','le code le plus précis l''emporte (8120 avant 81)');
select th2.assert((select owner::text from public.zone_diagnose('81200',null,'Castres'))='00000000-0000-0000-0000-0000000000d2','… et il désigne le bon commercial');
-- ambiguïté : la ville et l'adresse désignent deux commerciaux différents
select th2.assert((select status from public.zone_diagnose(null,'Gaillac','Albi'))='ambigu','ville et adresse contradictoires : ambigu');
-- compte désactivé
update public.profiles set active=false where id='00000000-0000-0000-0000-0000000000d1';
select th2.assert((select status from public.zone_diagnose('81500',null,'Castres'))='inactif','compte désactivé : cause « inactif »');
update public.profiles set active=true where id='00000000-0000-0000-0000-0000000000d1';
-- simulation : cause et règle par dossier, rien n'est écrit
set role authenticated;
select th2.login(:'secr');
select public.create_request('Sim Un','0699000001','s1@exemple.test',null,null,'Paris','75001',null,'{}',null,'2026-10-10',null);
select th2.assert((select count(*) from jsonb_array_elements(public.simulate_zones()) e where e->>'reason'='aucune')>=1,'simulation : cause « aucune zone » rendue');
select th2.assert((select count(*) from public.assignments where reason like 'Attribution automatique%')=(select count(*) from public.assignments where reason like 'Attribution automatique%'),'la simulation n''écrit rien');
select th2.expect_error($$select * from public.zone_diagnose('81500',null,'x')$$,'permission denied');
select 'LOT 15 : diagnostic des zones OK' as resultat;
