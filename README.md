# CRM C2e

CRM commercial privé (travaux énergétiques). Cahier des charges : version 1 du 26/10/2026.

## État
**Lot 1 (socle base de données) fait** : rôles (admin, secrétariat, commercial), référentiels
(sources et travaux du classeur de septembre 2026), contacts, demandes, attribution et
réattribution tracées, journal d'audit, contrôle de version, désactivation d'un commercial
avec file « à réattribuer ». Pas encore d'interface web (prochaine étape du Lot 1).

## Choix techniques
- Supabase (Postgres + comptes). Les droits sont appliqués **dans la base** (RLS) : un commercial
  ne peut lire que ses dossiers, même en modifiant une URL ou une requête.
- Aucune écriture directe sur les tables : tout passe par des fonctions (`create_request`,
  `assign_requests`, `update_contact_info`, `admin_set_role`, `admin_set_active`).
- Un projet Supabase dédié reste à créer (aucun n'existe encore).

## Tester (aucun service externe)
`./tests/run.sh` lance un Postgres jetable, applique la migration et vérifie l'isolation des
commerciaux, l'attribution, les conflits de version et la désactivation. Données 100 % fictives.

## Reste à décider
Voir la fin du cahier des charges (relance mail, fournisseur d'envoi, hébergement, conservation).
Le classeur Excel réel contient des données de prospects : ne pas le versionner dans ce dépôt.
