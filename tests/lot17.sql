\set ON_ERROR_STOP on
\set adm  '00000000-0000-0000-0000-0000000000a1'
\set secr '00000000-0000-0000-0000-0000000000b1'
update public.profiles set active=true;
insert into public.sources (name) values ('Alias Test Principal'),('Alias Test Variante'),('Alias Test Autre') on conflict do nothing;
create temp table s17 as select (select id from public.sources where name='Alias Test Principal') p, (select id from public.sources where name='Alias Test Variante') v, (select id from public.sources where name='Alias Test Autre') o;
grant select on s17 to authenticated;
set role authenticated;
select th2.login(:'secr');
select th2.expect_error($$select public.set_source_alias((select v from s17),(select p from s17))$$,'FORBIDDEN');
select th2.login(:'adm');
select public.set_source_alias((select v from s17),(select p from s17));
select th2.assert((select alias_of from public.sources where id=(select v from s17))=(select p from s17),'alias enregistré');
select th2.assert((select count(*) from public.sources where name in ('Alias Test Principal','Alias Test Variante'))=2,'aucune source supprimée ni fusionnée');
select th2.expect_error($$select public.set_source_alias((select p from s17),(select o from s17))$$,'HAS_ALIASES');
select th2.expect_error($$select public.set_source_alias((select o from s17),(select v from s17))$$,'BAD_ALIAS');
select th2.expect_error($$select public.set_source_alias((select o from s17),(select o from s17))$$,'BAD_ALIAS');
select public.set_source_alias((select v from s17), null);
select th2.assert((select alias_of is null from public.sources where id=(select v from s17)),'alias retiré (réversible)');
select public.set_source_short_name((select p from s17),'  Alias court ');
select th2.assert((select short_name from public.sources where id=(select p from s17))='Alias court','nom court enregistré');
select th2.assert((select count(*) from public.audit_log where action='set_source_alias')>=2,'rapprochements journalisés');
select 'LOT 17 : alias de sources OK' as resultat;
