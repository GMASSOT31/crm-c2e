# CRM C2e — mémoire du projet (à lire en premier)

## 1. Objectif
CRM privé en français pour C2E Habitat (rénovation énergétique), pensé **d'abord pour le téléphone** (outil principal des commerciaux).
- Rôles : **commercial** (ne voit que ses dossiers), **secrétariat** (ajoute des leads, attribue), **admin**, et **super admin** (Gabriel : reçoit les « Retours »).
- Fonctions : contacts/demandes, attribution manuelle + automatique par zones (code postal puis ville), appels sans réponse (3 → tâche mail de relance), rappels, « RDV pris », « Devis à faire », devis, ventes, clôture, import Excel/CSV avec contrôle des doublons, export, pilotage et **Statistiques** (classements, taux de transformation, CA), rubrique **Retours** (envoi par l'équipe, statut Traité / À discuter), alerte mail au super admin.
- L'utilisateur (Gabriel) **n'est pas technique** : réponses en français simple, sans jargon, faire les manipulations soi-même, aller vite.

## 2. Stack
- Front : **un seul fichier** `docs/index.html` (JS vanilla dans une IIFE, sans framework), servi par **GitHub Pages** (dépôt public GMASSOT31/crm-c2e, branche `main`, dossier `/docs`) → https://gmassot31.github.io/crm-c2e/ . supabase-js 2.118.0 (jsdelivr), SheetJS (cdnjs). Graphiques SVG faits main. Marque : vert `--accent #62dd4a`, polices Outfit / Plus Jakarta Sans / Public Sans, mode sombre, barre d'onglets en bas sur téléphone, `table.rt` devient des cartes.
- Back : **Supabase** projet `zjtpqcfhpezlqgaqybhe` (org « C2e »), Postgres 17. Droits dans la base (RLS). **Aucune écriture directe** : tout passe par des fonctions RPC `SECURITY DEFINER` avec `search_path=''`, contrôle de version (concurrence optimiste), `audit_log`, jeton anti double-clic. La clé « publishable » dans le code est normale ; aucune autre clé dans le dépôt.
- Fonctions Edge (`supabase/functions/`) : `inviter-utilisateur` (admin : lien d'invitation / mot de passe provisoire / réinitialisation ; changement obligatoire au 1er accès, 12 caractères min.) ; `notifier-retour` (mail au super admin via **Resend**, secret `RESEND_API_KEY`, sans lui ne fait rien).
- Connexion : l'identifiant sans « @ » reçoit `@crm.local` (ex. « admin »).

## 3. Fichiers importants
- `docs/index.html` : toute l'appli (login, `start()`, `loadAll()`, `tabsFor()`, vues vHome/vHomeCom/vContacts/vAdd/vImport/vAssign/vStats/vDash/vTeam/vZones/vFb, `act()`, gestionnaires `click` délégués, table d'erreurs `ERR`).
- `supabase/migrations/` : 01 socle, 02 activités, 03 équipe/qualité, 04 journal/export, 05 import historique, 06 attribution classeur, 07 zones (remplacée par 08), 08 zones par nom (`zone_rules`, `name_sig`), 09 devis à faire, 10 retours (`feedback`, `is_super`), 11 alerte retour (`notified_at`), 12 dates et provenance (+ sauvegarde `backup_20261027`), 13 notes/RDV/actions, 14 attribution en masse, 15 doublons (`duplicate_reviews`) et opposition bloquante, 16 import avec date de réception, 17 relances de devis / suite justifiée / annulation d'action, 18 diagnostic des zones. **Toutes appliquées** sur la base en ligne. `supabase/installation_complete.sql` est périmé (s'arrête vers la migration 04).
- `tests/run.sh` (Postgres jetable local, `lot1..lot15.sql` + `kpi.test.js`, tous verts) · `tests/ui_mock.js` (navigateur, client simulé) · `demo/index.html` (prototype à données fictives) · `README.md` (périmé : décrit seulement le Lot 1).

## 4. Règles de travail
- Une branche `claude/<sujet>` + une PR par changement, fusion en squash. **Demander avant de toucher à la base** ; appliquer la migration à Supabase **avant** de fusionner la PR qui l'utilise, puis ajouter le fichier dans `supabase/migrations/`.
- **Éviter les mots « delete/drop/truncate »** dans le SQL passé par l'outil MCP (confirmation invisible → blocage). Préférer désactiver (`active=false`, annulation) à supprimer.
- Ne jamais taper ni afficher de mot de passe/clé ; la clé Resend se met à la main dans Supabase › Edge Functions › Secrets.
- Avant PR : `./tests/run.sh`, vérification de syntaxe du script, test Playwright avec client Supabase simulé (le bac à sable n'atteint ni Supabase, ni les CDN, ni c2e-habitat.fr).
- Commits au nom `GMASSOT31 <258298134+GMASSOT31@users.noreply.github.com>` avec les lignes `Co-Authored-By` / `Claude-Session` demandées ; PR terminée par `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- Après chaque fusion en squash, le hook d'arrêt signale à tort des « commits non poussés » : `git fetch -q origin main && git checkout -q -B claude/suite origin/main`. Ne jamais réécrire l'historique.

## 5. État actuel (27/10/2026)
- En ligne : tout ce qui précède **et** les Lots 1 à 5 du cahier des charges du 27/10 (`diagnostic/lot1-constat.md`, `lot4-constat.md`, `recette.md`) : une seule couche de calcul `KPI` (dans `docs/index.html`, testée par `tests/kpi.test.js`), dates de réception/import séparées, alertes qualité et file « à vérifier », liste Contacts refaite, notes signées, cycle du RDV, agenda, attribution en masse avec simulation des zones, Équipe en 3 rubriques, définitions des indicateurs, clavier/mobile.
- Migrations 12 à 18 appliquées (voir §3). Tests : `./tests/run.sh` (lots 1 à 15 + KPI) et `node tests/ui_mock.js` (navigateur, client simulé).
- Base : 312 contacts, aucun n'a de date de réception (jamais remplacée par la date d'import) ; 78 validés, 234 à vérifier ; RDV du classeur = « à dater » ou « planifié ».
- Alerte mail : **active et testée le 27/10/2026** (clé `RESEND_API_KEY` ajoutée par Gabriel ; mail reçu sur gabriel.massot@hotmail.com, expéditeur de test `onboarding@resend.dev` : il n'écrit qu'à l'adresse du compte Resend). Les « 17 dossiers d'octobre » : réglé le 27/10/2026, règle « commercial du classeur » appliquée, aucun écart avec les zones (146/146 identiques). Reste à attribuer : 74 dossiers de septembre sans code postal, via Équipe › Reprise historique (Yann RICHECOEUR 36, Alexis JOYEUX 28, Vincent BOUSCATEL 6, Christophe LAMY 2, François LLEIDA 1, Rémy BOUSCATEL 1).
- Après un squash-merge, repartir de main : `git fetch -q origin main && git checkout -q -B <branche> origin/main`, puis `git push --force-with-lease` (la branche distante ne contient que de l'historique déjà fusionné).

- Cahier des charges du 27/10 : tout est réalisé (lots 1 à 5, puis QUA02 doublons, ENT02 ajout/import, RAP01 devis/ventes, ATT02 zones, KPI05 périodes, DAT03 noms). **Non réalisé** : alias de sources (Google, SolarEdge), à valider par Gabriel avant toute fusion de libellés ; fusion automatique de deux dossiers doublons (facultative). Les 4 dossiers sans coordonnées (OEUILLET, LARUE, BOURGES, TAGLIAPIETRA) restent à attribuer à Yann RICHECOEUR avec dérogation admin.

## 6. Prochaines étapes (selon la demande de Gabriel)
- Essai sur vrais téléphones par les commerciaux ; logo officiel C2E Habitat (le logo actuel est reconstitué).
- Envoi réel du mail de relance après 3 appels sans réponse, modèles de mails modifiables.
- Bouton d'annulation d'import, fusion des doublons, politique de conservation, sauvegardes (offre Pro de Supabase à conseiller), mise à jour du `README.md` et de `installation_complete.sql`.
