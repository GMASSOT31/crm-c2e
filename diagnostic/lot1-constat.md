# Lot 1 : constat technique (27/10/2026)

Rien n'a été modifié dans l'appli ni dans la base : lecture du code (`docs/index.html`) et requêtes de lecture seule sur Supabase.

## 1. Pourquoi les chiffres se contredisent

Faits mesurés sur la base en ligne :
- 312 demandes, **aucune n'a de date de réception** (`received_on` vide pour les 312).
- Les 312 ont la même date de création technique : le 26/10/2026 (jour de l'import).
- Les 312 ont la qualité « à vérifier » : **0 validée**, 0 doublon, 0 spam.
- 146 attribuées, 126 ouvertes non attribuées, 40 non attribuées mais clôturées (146 + 126 + 40 = 312).
- 118 au statut « RDV pris » (importé du classeur), dont seulement 64 ont une date de RDV. 0 vente.
- 3 activités au total, toutes de type « contact », sur le même dossier (n° 303), à 8 minutes de l'attribution.

| Écran | Ce qu'il calcule | Résultat | Cause |
|---|---|---|---|
| Accueil / Pilotage | « Exploitables » = qualité *valide* | 0 | Aucune demande validée : c'est cohérent avec la règle du cahier des charges |
| Statistiques (`dashModel`) | « Exploitables » = tout ce qui n'est pas doublon/spam | 312 | Règle différente de Pilotage : les « à vérifier » comptent comme exploitables |
| Pilotage | RDV = date de RDV renseignée (`rdv_on`) | 0 ici (filtre sur valides), 64 au total | Compte le champ date |
| Statistiques | RDV = date, ou statut RDV pris, ou activité | 119 | Compte le statut importé du classeur comme un vrai RDV |
| Filtre « RDV pris » | statut = RDV pris | 118 | 54 de ces dossiers n'ont aucune date de RDV |
| Statistiques « 146 attribués / 166 en attente » | non attribué = pas de responsable | 166 | Inclut les 40 clôturés ; Attribution n'en compte que 126 (ouverts) |
| Réactivité 8 minutes | délai entre attribution et 1re activité | 8 min | Calculé sur **un seul dossier** (tests du 26/10), présenté comme moyenne de l'équipe |
| « Tout » affiche 26 → 27 octobre | période « Tout » | 26/10 | Repli sur la **date de création** (`received_on || created_at`) quand la date de réception manque : la date d'import est prise pour une date métier |

Cause racine : **cinq endroits calculent chacun leur propre règle** (`vHome`, `vStats`, `dashModel`, `filtered`, `vAssign`), et les dates importées manquantes sont remplacées par la date d'import.

## 2. Bug d'extraction du nom (« Dubois Laura » → « Laura »)

Fichier `docs/index.html`, fonction `parseMail`, ligne `Nom …` : l'expression `^nom\b(?!\s+du)` voulait écarter « Nom du formulaire », mais elle est insensible à la casse et refuse donc aussi « Nom **Du**bois ». Tous les noms commençant par « Du » (Dubois, Dupont, Durand…) perdent leur nom. Reproduit en test. Correction prévue au Lot 2.

## 3. Où sont les définitions aujourd'hui

- `unassigned()`, `untreated()`, `lateTasks()` : règles de l'Accueil.
- `vStats` : cohorte = `received_on || created_at`, exploitable = qualité valide.
- `dashModel` : exploitable = hors doublon/spam, RDV/devis/vente déduits du statut OU des dates OU des activités, réactivité sur les activités.
- Le calcul des chiffres se fait **dans le navigateur** à partir de toutes les demandes chargées (aucune fonction de calcul côté base).

## 4. Plan de migration proposé (réversible, sans suppression)

Migration 12 : *dates et provenance* (ajout uniquement)
- Ajouter `received_at` (horodatage, facultatif), `received_precision` (jour / minute / inconnue), `received_source` (formulaire, import, note…), `imported_at`.
- Reprise : copier `received_on` existant (aucune valeur pour l'instant) ; **ne jamais** remplir avec `created_at`.
- Ajouter `rdv_origin` (importé sans date / confirmé), `first_action_at` calculé uniquement depuis les vrais événements métier.
- Évènement technique « Import historique » (hors comptes d'appels, RDV, ventes).
- Sauvegarde : copie des tables `requests`, `contacts`, `activities` dans un schéma `backup_20261027` avant toute modification. Rapport avant/après (312 = 312, identifiants conservés).

Migration 13 : *couche de calcul unique*
- Fonction SQL `kpi_summary(from, to, commercial)` (heure de Paris) qui renvoie reçus, exploitables validés, à vérifier, non attribués ouverts, à réattribuer, non traités, en retard, RDV obtenus, taux, ventes, CA HT / TTC séparés, réactivité (avec nombre de dossiers pris en compte).
- Les écrans appellent cette même fonction ; les listes ouvertes depuis les cartes utilisent les mêmes identifiants.

Côté appli : remplacer les 5 calculs par l'appel unique, afficher « Date de réception non renseignée », corriger `parseMail`, libellés du vocabulaire (cf. dictionnaire ci-dessous).

## 5. Dictionnaire des indicateurs (à implémenter au Lot 2)

| Indicateur | Numérateur / contenu | Dénominateur | Exclusions | Si donnée manquante |
|---|---|---|---|---|
| Reçus | demandes dont la date de réception connue est dans la période (heure de Paris) | : | archivés | affichés à part : « sans date de réception » |
| Exploitables validés | qualité *valide* | : | doublon, spam, opposition ; une clôture ne retire pas | : |
| À vérifier | qualité *à vérifier* | : | : | : |
| Non attribués ouverts | sans commercial actif, non clôturés | : | doublon, spam, opposition ; clôturés = catégorie à part | : |
| À réattribuer | ouverts dont le responsable est inactif ou absent (sans double compte avec « non attribués ») | : | : | : |
| Non traités | exploitables attribués sans action métier (ni import, ni ouverture, ni attribution) | : | reprises historiques à statut incertain : comptées à part | : |
| En retard | actions non terminées dont l'échéance est dépassée | : | échéance sans heure : en retard le jour suivant (heure de Paris) | : |
| Dossiers avec RDV | dossiers ayant eu au moins un RDV confirmé | : | un dossier compté une fois | jalons importés sans date : comptés à part, inclusion explicite |
| Taux RDV | dossiers validés de la cohorte ayant obtenu un RDV | validés de la cohorte | non validés importés « RDV pris » présentés à part | dénominateur 0 → « Non calculable » |
| Taux de vente | ventes de la cohorte | validés de la cohorte | : | idem |
| Réactivité | délai réception → 1re action métier | échantillon exploitable | imports, changements de qualité, consultations, délais négatifs, dates inconnues | affiche le nombre pris en compte ; sinon « Non calculable » |
| CA | somme des montants | : | : | HT et TTC séparés, jamais additionnés ; ventes sans montant comptées à part ; panier moyen sur un périmètre homogène |

## 6. Ce que cela change pour vos données actuelles

Avec ces règles, vos 312 contacts afficheront : 312 « sans date de réception », 0 exploitable validé, 312 à vérifier. C'est **exact**, mais l'accueil paraîtra « vide » tant que la qualité n'est pas validée. Voir la question posée dans le suivi.
