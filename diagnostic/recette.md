# Recette du cahier des charges (27/10/2026) : compte rendu de validation

Contrôles lancés par `./tests/run.sh` (base de test jetable, lots 1 à 11, indicateurs) et `node tests/ui_mock.js` (navigateur, client Supabase simulé, jeu fictif). Aucun envoi réel, aucune réattribution réelle, données de test synthétiques.

| Scénario | Résultat | Où c'est vérifié |
|---|---|---|
| T01 mêmes filtres, cartes, tableaux, exports | Réussi : une seule couche de calcul (`KPI`), les cartes ouvrent les mêmes identifiants, l'export reprend la liste filtrée | `tests/kpi.test.js`, `ui_mock.js` |
| T02 période vide, dates inconnues, dernier jour, changement d'heure | Réussi (heure de Paris, 25/10/2026) | `tests/kpi.test.js` |
| T03 extraction du texte (Dubois / Laura, « Nom et prénom », « Nom complet », apostrophes, nom du formulaire seul) | Réussi | `ui_mock.js` |
| T04 deux RDV, un seul dossier | Réussi | `tests/kpi.test.js` |
| T05 import rejoué | Réussi : empreinte du fichier (`ALREADY_IMPORTED`), aucun envoi dans l'application | `tests/lot3.sql` |
| T06 ville structurée dans la liste et la fiche | Réussi (code postal affiché à défaut de ville, rien d'inventé) | `ui_mock.js` |
| T07 attribution sur plusieurs pages, simulation des zones | Réussi : seule la sélection annoncée est traitée, échecs expliqués par motif | `tests/lot10.sql`, `ui_mock.js` |
| T08 rappel terminé, échéance sans heure | Réussi : terminé = plus en retard ; journée sans heure = retard le lendemain (minuit de Paris) | `tests/lot9.sql`, `tests/kpi.test.js` |
| T09 trois appels sans réponse, simulation, opposition | Réussi : une seule tâche mail, opposition bloquante, aucun envoi automatique | `tests/lot2.sql`, `tests/lot10.sql` |
| T10 notes, clôture, réouverture, report de RDV, double clic | Réussi | `tests/lot9.sql`, `tests/lot11.sql` |
| T11 deux commerciaux et un administrateur, désactivation | Réussi : isolation des dossiers, historique conservé, accès coupé | `tests/lot11.sql` |
| T12 clavier, fenêtre étroite, retour depuis une fiche, erreur de sauvegarde | Réussi en partie : Entrée/Échap/focus, 360/390/768/1366 px sans défilement horizontal, saisie conservée après erreur. **Non testés** : zoom à 200 %, coupure réseau réelle | `ui_mock.js` |
| T13 ventes HT/TTC/sans montant/montant nul, podium vide ou ex æquo | Réussi (calcul) ; podium neutre implémenté, vérifié à la lecture | `tests/kpi.test.js` |
| T14 mode exemple | Réussi : bandeau « Données fictives » sur tous les écrans, sortie évidente, aucune écriture | `ui_mock.js` |

## Jeu de référence A à I
Reçus 8 ; exploitables validés 5 ; à vérifier 1 ; doublon 1 ; spam 1 ; non attribués ouverts 2 ; clôturé non attribué 1 ; non traité attribué 1 ; H présenté à part ; taux RDV 20 % ; taux de vente 20 % ; réactivité 90 min (2 dossiers) ; CA 10 000 € HT, aucun CA TTC. Tout est vérifié dans `tests/kpi.test.js`.

## Limites restantes
- Aucun test sur de vrais téléphones ni avec de vrais comptes en ligne.
- Retards : une échéance sans heure n'est gérée que pour les rappels créés avec la fonction « journée » (les anciens rappels ont une heure).
- L'événement technique « Import historique » n'existe pas : la date d'import (`imported_at`) en tient lieu.
- Fusion automatique de deux dossiers doublons non réalisée (facultative) : la comparaison, la décision (doublon confirmé ou gardés distincts avec justification), l'annulation et la trace sont faites (QUA02).
- Alias de sources (Google, SolarEdge) non réalisés : à valider par le propriétaire avant de rapprocher des libellés.

## Points ajoutés après le Lot 5
QUA02 doublons et opposition bloquante (migration 15), ENT02 ajout et import (16), RAP01 devis, ventes, relances (17), ATT02 zones et KPI05 périodes (18), DAT03 noms et prénoms. Tests : lots 12 à 15 et `ui_mock.js`.

## À valider par le propriétaire
1. Le chiffre d'affaires principal est en **HT** ; le TTC est affiché à côté, jamais additionné.
2. Seuil des « dossiers inactifs » : 30 jours par défaut (modifiable dans la liste).
3. 78 dossiers attribués et sans avertissement ont été validés ; 68 avec avertissement restent à vérifier par le secrétariat.
4. La copie de sécurité `backup_20261027` reste en base : à supprimer plus tard, sur demande.
