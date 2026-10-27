# Lot 4 : attribution et équipe (27/10/2026)

## Déclencheur exact de l'attribution automatique (vérifié dans le code)
- `create_request` (nouvelle demande saisie dans « Ajouter » ou collée) appelle `zone_assign_one` juste après l'enregistrement.
- `zone_assign_one` n'attribue que si : demande non attribuée, non archivée, ni doublon ni spam, non clôturée, contact **complet** (nom + téléphone ou email), et zone connue sans ambiguïté avec un commercial **actif**. Sinon elle ne fait rien, sans erreur.
- Un brouillon non enregistré n'est jamais attribué. Un dossier enregistré incomplet reste « à attribuer ».
- L'import Excel n'appelle pas les zones : il garde le commercial du classeur. Les zones s'appliquent ensuite avec « Appliquer » (`apply_zones`).
- Aucun appel, aucun mail n'est créé par ces chemins. `apply_zones` rejouée ne change rien (testé).

## Ce qui a changé
- `simulate_zones()` : même périmètre et même règle que `apply_zones()`, sans rien écrire.
- `assign_requests_report()` : chaque dossier est traité séparément ; les échecs sont rendus avec leur motif (incomplet, déjà attribué entre-temps, opposition, clôturé, doublon/spam, introuvable). Un dossier déjà attribué à un commercial actif n'est jamais repris (pas de double traitement). La dérogation est réservée à l'administrateur, exige une justification tracée et ne contourne ni l'opposition ni les droits.
- Page Attribution : recherche et filtres (département, ville, code postal, source, travaux, motif de blocage), pagination, « sélectionner cette page » distinct de « sélectionner tous les résultats filtrés », barre de sélection, prévisualisation de la charge avant et après, confirmation, rapport succès/échecs.
- Page Équipe en 3 sous-rubriques ; désactivation, changement de rôle et nouveau mot de passe demandent une confirmation (plus de déclenchement par une simple touche du clavier sur une liste).
- Correction d'un défaut existant : le bouton Désactiver/Réactiver lisait l'identifiant du compte comme un nombre et ne pouvait pas fonctionner.

## Limites restantes
- La simulation ne distingue pas encore « aucune zone », « zone ambiguë » et « commercial sans compte actif » : les trois sont rendus « zone non couverte, ambiguë ou sans compte actif ».
- Les codes de longueur particulière (ni 2 ni 5 chiffres) sont refusés à la saisie des règles (`BAD_ZONE`).
- Le dernier administrateur ne peut pas être retiré : on ne peut ni désactiver ni rétrograder son propre compte, donc il reste toujours un administrateur actif.
