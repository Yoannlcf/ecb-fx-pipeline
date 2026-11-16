# ecb-fx-pipeline

Pipeline batch des taux de change de référence publiés par la Banque centrale
européenne (BCE).

## État du projet

**En construction.** Ce README décrit uniquement ce que le code fait
aujourd'hui.

À ce jour, le dépôt contient :

- le squelette du projet Python (`ingestion/`, `tests/`) ;
- la configuration du lint et du formatage (ruff, pre-commit) ;
- une CI GitHub Actions qui vérifie le lint et le formatage.

Il n'y a pas encore de code d'ingestion, de base de données ni de
transformation.

## Développement

Prérequis : Python 3.11 ou plus, `make`.

```bash
make install   # outils de dev + hooks pre-commit
make lint      # mêmes vérifications que la CI
```

## Licence

MIT
