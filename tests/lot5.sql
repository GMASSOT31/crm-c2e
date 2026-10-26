\set ON_ERROR_STOP on
\set adm  '00000000-0000-0000-0000-0000000000a1'
\set secr '00000000-0000-0000-0000-0000000000b1'
\set ca   '00000000-0000-0000-0000-0000000000c1'
update public.profiles set active=true;
update public.profiles set full_name='Commercial A Fictif' where id=:'ca';
update public.zone_rules set active=false;
set role authenticated;
select th2.login(:'adm');
-- règles par nom, y compris pour un commercial sans compte
select th2.assert((public.set_zone_rules('[{"postal":9100,"label":"JOYEUX Alexis"},{"postal":"31000","label":"Fictif Commercial A"},{"postal":"31200","label":"SANS COMPTE Zoe"},{"postal":"xx","label":"Z"}]'::jsonb))->>'applied' = '3', '3 règles appliquées, 1 rejetée');
select th2.login(:'secr');
create temp table q as select
  public.create_request('Zone nom A','0611000101',null,1,null,'Toulouse','31000') a,
  public.create_request('Zone sans compte','0611000102',null,1,null,'Toulouse','31200') b,
  public.create_request('Zone zéro initial','0611000103',null,1,null,'Pamiers','09100') c;
grant select on q to authenticated;
select th2.assert((select assigned_to from public.requests where id=(select a from q)) = :'ca'::uuid, 'règle par nom reliée au compte (ordre des mots libre)');
select th2.assert((select assigned_to from public.requests where id=(select b from q)) is null, 'commercial sans compte : pas d''attribution');
select th2.assert((select assigned_to from public.requests where id=(select c from q)) is null, 'zone 09100 sans compte : non attribué');
-- le compte apparaît ensuite : le trigger relie la zone, apply_zones attribue
reset role;
update public.profiles set full_name='Zoe SANS COMPTE' where id=:'ca';
set role authenticated;
select th2.login(:'secr');
select th2.assert((public.apply_zones())->>'assigned' = '1', 'apply_zones attribue au compte nouvellement relié');
select th2.assert((select assigned_to from public.requests where id=(select b from q)) = :'ca'::uuid, 'dossier attribué après création du compte');
select th2.login(:'adm');
select public.set_zone_label('Zoe SANS COMPTE', array['31200'], array[]::text[]);
select th2.expect_error($$select public.set_zone_label('Autre Personne', array['31200'], array[]::text[])$$, 'ZONE_TAKEN');
select th2.assert((select count(*) from public.zone_rules where label='Zoe SANS COMPTE' and active)=1, 'zones remplacées sans suppression');
select 'LOT 5 : zones par nom OK' as resultat;
