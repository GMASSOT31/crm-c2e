-- DONNÉES FICTIVES pour développement local uniquement (ne jamais exécuter en production).
-- Les comptes n'ont pas de mot de passe : en local, créer les vrais comptes via l'outil d'invitation.
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1','admin@exemple.test'),
  ('00000000-0000-0000-0000-0000000000b1','secretariat@exemple.test'),
  ('00000000-0000-0000-0000-0000000000c1','commercial.a@exemple.test'),
  ('00000000-0000-0000-0000-0000000000c2','commercial.b@exemple.test') on conflict do nothing;
insert into public.profiles (id, full_name, role) values
  ('00000000-0000-0000-0000-0000000000a1','Admin Fictif','admin'),
  ('00000000-0000-0000-0000-0000000000b1','Secrétaire Fictive','secretariat'),
  ('00000000-0000-0000-0000-0000000000c1','Commercial A Fictif','commercial'),
  ('00000000-0000-0000-0000-0000000000c2','Commercial B Fictif','commercial') on conflict do nothing;
