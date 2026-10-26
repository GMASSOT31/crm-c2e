\set ON_ERROR_STOP on
\set adm  '00000000-0000-0000-0000-0000000000a1'
\set secr '00000000-0000-0000-0000-0000000000b1'
\set ca   '00000000-0000-0000-0000-0000000000c1'
\set cb   '00000000-0000-0000-0000-0000000000c2'
update public.profiles set active=true;
set role authenticated;
select th2.login(:'secr');
select th2.expect_error(format('select public.set_zones(%L::uuid, array[''31''], array[]::text[])', :'ca'), 'FORBIDDEN');
select th2.login(:'adm');
select public.set_zones(:'ca', array['31','7600'], array['Colomiers']);
select public.set_zones(:'cb', array['3120','32'], array['Saint-Orens']);
select th2.expect_error(format('select public.set_zones(%L::uuid, array[''31''], array[]::text[])', :'cb'), 'ZONE_TAKEN');
select th2.expect_error(format('select public.set_zones(%L::uuid, array[''ab''], array[]::text[])', :'cb'), 'BAD_ZONE');
select th2.login(:'secr');
create temp table z as select
  public.create_request('Zone A','0611000001',null,1,null,'Toulouse','31500') a,
  public.create_request('Zone B plus precis','0611000002',null,1,null,'Toulouse','31200') b,
  public.create_request('Zone C hors zone','0611000003',null,1,null,'Paris','75001') c,
  public.create_request('Zone D ville','0611000004',null,1,null,'COLOMIERS',null) d,
  public.create_request('Zone E ville accent','0611000005',null,1,null,'saint orens',null) e,
  public.create_request(null,null,null,1,null,'Toulouse','31500') f,
  public.create_request('Zone G adresse','0611000007',null,1,null,null,null,'5 rue X 32100 Condom') g;
grant select on z to authenticated;
select th2.assert((select assigned_to from public.requests where id=(select a from z)) = :'ca'::uuid, '31500 -> A');
select th2.assert((select assigned_to from public.requests where id=(select b from z)) = :'cb'::uuid, '31200 plus précis -> B');
select th2.assert((select assigned_to from public.requests where id=(select c from z)) is null, 'hors zone non attribué');
select th2.assert((select assigned_to from public.requests where id=(select d from z)) = :'ca'::uuid, 'ville Colomiers -> A');
select th2.assert((select assigned_to from public.requests where id=(select e from z)) = :'cb'::uuid, 'ville sans accent/tiret -> B');
select th2.assert((select assigned_to from public.requests where id=(select f from z)) is null, 'dossier incomplet jamais attribué');
select th2.assert((select assigned_to from public.requests where id=(select g from z)) = :'cb'::uuid, 'code postal lu dans l''adresse -> B');
select th2.assert((select count(*) from public.tasks where request_id in (select a from z union select b from z)) = 0, 'aucune tâche créée');
-- apply_zones sur des dossiers non attribués
select th2.login(:'adm');
select public.set_zones(:'ca', array['31','7600','75'], array['Colomiers']);
select th2.login(:'secr');
select th2.assert((public.apply_zones())->>'assigned' = '1', 'apply_zones : le dossier 75001 est attribué');
select th2.assert((select assigned_to from public.requests where id=(select c from z)) = :'ca'::uuid, '75001 -> A après ajout de zone');
select 'LOT 4 : zones OK' as resultat;
