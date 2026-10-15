# Campus E-sport Cup — SQL avancé

Base PostgreSQL de gestion d'un tournoi e-sport : équipes, joueurs, tournoi et matchs. Le script contient les éléments demandés dans le sujet SQL avancé B2 : fonction, trigger, deux rôles, deux vues, deux index et 10 000 matchs de démonstration.

## Lancer le projet

Exécuter `projet.sql` avec un compte PostgreSQL administrateur sur une base vide :

```bash
psql -U postgres -d projet -f projet.sql
```

Le script génère 10 000 matchs via `generate_series`, puis mesure une requête avec `EXPLAIN (ANALYZE, BUFFERS)` avant et après création des index. Les temps exacts dépendent de la machine et du plan choisi par PostgreSQL : ils doivent être relevés dans la sortie réelle, ils ne sont pas préinventés ici.

## Fonction

- **Ce qu'elle fait :** `validate_match_result(id)` vérifie qu'un match existe et que ses deux scores sont renseignés, puis marque le résultat comme validé.
- **Pourquoi :** centraliser la validation dans la base pour que la règle soit la même quel que soit le client.
- **Preuve :** `SELECT validate_match_result(1);` renvoie un message de confirmation si le score est complet.

## Trigger

- **Ce qu'il fait :** `trg_protect_validated_result` empêche de modifier les scores ou les équipes d'un match déjà validé.
- **Pourquoi dans la base :** toute application connectée à la base est soumise à la règle, pas seulement une interface particulière.
- **Preuve :** après `SELECT validate_match_result(1);`, tenter `UPDATE matches SET home_score = 99 WHERE match_id = 1;`. PostgreSQL doit refuser avec un message explicite.

## Rôles et privilèges

- **Ce qu'ils font :** `operator_user` reçoit le rôle métier `tournament_operator`; `auditor_user` reçoit `tournament_auditor`. Les mots de passe sont uniquement des identifiants de démonstration.
- **Pourquoi :** appliquer le principe du moindre privilège. Les rôles métier ont accès à leur vue, mais pas directement aux tables.
- **Preuve :** `SET ROLE operator_user; SELECT * FROM v_operator_matches LIMIT 5;` fonctionne, tandis que `SELECT * FROM matches;` est refusé. Pour l'auditeur, utiliser `SET ROLE auditor_user; SELECT * FROM v_auditor_results LIMIT 5;`.

## Vues

- **Ce qu'elles font :** `v_operator_matches` présente les matchs à l'opérateur; `v_auditor_results` ne montre que les résultats validés.
- **Pourquoi :** fournir une interface simplifiée et limiter les données visibles.
- **Preuve :** comparer les lignes des deux vues, puis vérifier qu'un rôle ne peut pas lire la vue réservée à l'autre.

## Index

- **Ce qu'ils font :** `idx_matches_played_at` indexe la date du match; `idx_matches_tournament_date` indexe le tournoi puis la date.
- **Pourquoi :** accélérer les recherches par date et les requêtes filtrées par tournoi et date.
- **Preuve :** lire `Execution Time` dans les deux sorties `EXPLAIN ANALYZE` du script. Ne pas annoncer de gain chiffré avant d'avoir exécuté le script; PostgreSQL peut choisir un parcours séquentiel selon les données et la machine.

## Volume de données

La table `matches` contient 10 000 lignes générées avec `generate_series(1, 10000)`. Vérification : `SELECT COUNT(*) FROM matches;`.

## Remarques

Le script est prévu pour une base vide. Les rôles sont créés de manière conditionnelle afin d'éviter l'erreur `role already exists` si le script est relancé sur le même serveur. Les mots de passe inclus sont réservés à la démonstration et doivent être changés hors contexte scolaire.
