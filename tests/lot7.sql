\set ON_ERROR_STOP on
\set adm  '00000000-0000-0000-0000-0000000000a1'
\set secr '00000000-0000-0000-0000-0000000000b1'
\set ca   '00000000-0000-0000-0000-0000000000c1'
\set cb   '00000000-0000-0000-0000-0000000000c2'
update public.profiles set active=true;
update public.profiles set is_super = (id = :'adm');
set role authenticated;
select th2.login(:'ca');
select public.send_feedback('probleme','Le bouton RDV ne répond pas','Fiche');
select th2.login(:'secr');
select public.send_feedback('idee','Ajouter une colonne téléphone');
select th2.expect_error($$select public.send_feedback('autre','a')$$, 'MESSAGE_TOO_SHORT');
select th2.assert((select count(*) from public.feedback) = 1, 'la secrétaire ne voit que son retour');
select th2.login(:'cb');
select th2.assert((select count(*) from public.feedback) = 0, 'un commercial ne voit pas les retours des autres');
select th2.expect_error($$select public.set_feedback_status(1,'traite')$$, 'FORBIDDEN');
select th2.login(:'adm');
select th2.assert((select count(*) from public.feedback) = 2, 'le super administrateur voit tout');
select public.set_feedback_status((select min(id) from public.feedback), 'a_discuter', 'On en parle jeudi');
select th2.assert((select status::text from public.feedback order by id limit 1) = 'a_discuter', 'statut à discuter');
select public.set_feedback_status((select min(id) from public.feedback), 'traite');
select th2.assert((select reply from public.feedback order by id limit 1) = 'On en parle jeudi', 'la réponse est conservée');
select th2.login(:'ca');
select th2.assert((select status::text from public.feedback) = 'traite', 'l''auteur voit le statut traité');
-- un administrateur qui n'est pas super ne peut pas traiter
reset role;
update public.profiles set is_super = false where id = :'adm';
set role authenticated;
select th2.login(:'adm');
select th2.expect_error($$select public.set_feedback_status(1,'nouveau')$$, 'FORBIDDEN');
select th2.assert((select count(*) from public.feedback) = 0, 'un administrateur simple ne voit que les siens');
select 'LOT 7 : retours OK' as resultat;
