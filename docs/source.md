# Source de données : taux de change de référence de la BCE

Exploration réalisée le 16 novembre 2026 avec `curl`, sur l'API SDMX du ECB Data Portal.
Documentation officielle : [ECB Data Portal, API data](https://data.ecb.europa.eu/help/api/data).

## 1. Requête de référence

```bash
curl -s "https://data-api.ecb.europa.eu/service/data/EXR/D..EUR.SP00.A?startPeriod=2026-11-13&endPeriod=2026-11-13&format=csvdata"
```

**Observé :** code HTTP 200, une ligne d'en-tête puis 29 lignes de données (une par devise).

Rôle de chaque morceau de l'URL :

- `service/data/` : point d'entrée de l'API pour récupérer des observations (et pas des métadonnées).
- `EXR` : le *dataflow*, c'est-à-dire le jeu de données « taux de change ».
- `D..EUR.SP00.A` : la clé de série, avec 5 dimensions séparées par des points, dans un ordre fixe (tableau ci-dessous).
- `startPeriod` / `endPeriod` : bornes de la période, au format `AAAA-MM-JJ`, incluses toutes les deux. Avec la même date des deux côtés, on demande un seul jour.
- `format=csvdata` : réponse en CSV (une ligne par observation) au lieu du XML SDMX par défaut. C'est plus simple à charger dans pandas ou dans un entrepôt.

| Position | Dimension | Valeur | Sens |
|---|---|---|---|
| 1 | FREQ | `D` | fréquence quotidienne |
| 2 | CURRENCY | *(vide)* | devise cotée : vide = joker, toutes les devises |
| 3 | CURRENCY_DENOM | `EUR` | devise de référence (le dénominateur) : l'euro |
| 4 | EXR_TYPE | `SP00` | type de taux : taux de référence |
| 5 | EXR_SUFFIX | `A` | moyenne / valeur standard |

La dimension laissée vide est CURRENCY. C'est pour ça qu'on reçoit une ligne par devise au lieu d'une seule série. Pour une seule devise, on écrirait `D.USD.EUR.SP00.A`.

**Conséquence pour le pipeline :** une seule requête par jour suffit pour toutes les devises. La date est le seul paramètre qui varie, ce qui rend l'ingestion facile à rejouer sur une période passée (backfill).

## 2. Colonnes

La réponse compte 32 colonnes. Mon script `explore_colonnes.py` a compté les valeurs distinctes sur les 29 devises du 13 novembre 2026 :

| Colonne | Valeurs distinctes |
|---|---|
| KEY, CURRENCY, OBS_VALUE, TITLE, TITLE_COMPL, UNIT | 29 |
| DECIMALS | 4 |
| COMPILATION | 3 |
| TIME_PERIOD | 1 (la requête porte sur un seul jour) |
| OBS_STATUS (valeur `A`) | 1 |
| Les 22 autres | 1 |

### Bronze : les 32 colonnes, telles quelles

Bronze est la copie brute et fidèle de ce que l'API a renvoyé. Si je me trompe dans une transformation, ou si un besoin nouveau apparaît, je peux reconstruire Silver depuis Bronze sans rappeler l'API. Si une colonne aujourd'hui constante se met à varier (dérive de schéma ou de contenu), je peux le détecter et l'auditer. Les colonnes « inutiles » ne coûtent presque rien en stockage, alors que les perdre serait irréversible.

### Silver : données nettoyées, encore proches de la source

Une table `stg_exchange_rates`, une ligne par devise et par jour. Les données sont typées et dédoublonnées, mais pas encore modélisées.

| Colonne Silver | Source | Raison |
|---|---|---|
| `rate_date` | TIME_PERIOD | date de l'observation, une partie de la clé unique |
| `currency_code` | CURRENCY | l'autre partie de la clé unique |
| `rate` | OBS_VALUE | la mesure. Stockée en `DECIMAL`, pas en `float`, pour ne pas perdre de précision |
| `obs_status` | OBS_STATUS | toujours `A` aujourd'hui, mais c'est un attribut de l'observation : si la BCE publie une valeur provisoire ou corrigée, je veux le voir et pouvoir tester dessus |
| `currency_title`, `currency_title_compl` | TITLE, TITLE_COMPL | libellés de la devise |
| `unit` | UNIT | devise dans laquelle le taux est exprimé, donc le sens du taux (section 4) |
| `decimals` | DECIMALS | précision propre à chaque devise |
| `compilation` | COMPILATION | texte de méthode propre à la devise |

**Ce que je ne garde pas en Silver :**

- `KEY` : elle se reconstruit à partir des 5 dimensions, c'est une redondance.
- FREQ, CURRENCY_DENOM, EXR_TYPE, EXR_SUFFIX : constantes par construction, puisque je les fixe dans la clé de ma requête.
- Les autres colonnes constantes sont des métadonnées de diffusion. Elles n'apportent rien à l'analyse.
- Exception, que je teste au lieu de la jeter en silence : `UNIT_MULT` (multiplicateur d'unité, constant aujourd'hui). S'il changeait, le taux serait à multiplier par une puissance de 10. Un test qualité vérifie donc qu'il reste constant.

### Gold : le modèle en étoile pour Power BI

Les tables de faits et de dimensions se construisent en Gold, à partir de Silver.

| Table | Grain | Colonnes principales |
|---|---|---|
| `fact_exchange_rate` | une ligne par devise et par jour | `rate_date`, `currency_code`, `rate`, `obs_status` |
| `dim_currency` | une ligne par devise | `currency_code`, `title`, `title_compl`, `unit`, `decimals`, `compilation`, `first_seen`, `last_seen` |
| `dim_date` | une ligne par jour calendaire | date, jour de la semaine, mois, année, jour publié ou non |

`first_seen` et `last_seen` sont calculées à partir de l'historique des faits, parce que la liste des devises change dans le temps (section 5).

## 3. Jours sans données

| Requête | Code HTTP | Corps de la réponse |
|---|---|---|
| Samedi 14 novembre 2026 | 200 | Vide |
| Mardi 1er décembre 2026 (futur) | 000 | **À refaire** : aucune réponse HTTP reçue |

Le `000` vient de curl, pas de l'API : la connexion n'a pas abouti. À relancer avec affichage des erreurs, puis mettre à jour la ligne du tableau :

```bash
curl -sS -i "https://data-api.ecb.europa.eu/service/data/EXR/D..EUR.SP00.A?startPeriod=2026-12-01&endPeriod=2026-12-01&format=csvdata"
```

**Interprétation :** une réponse 200 vide doit être traitée comme « pas de publication ce jour-là », et non comme une erreur. La BCE ne publie ni le week-end ni les jours de fermeture TARGET : un samedi vide est donc le comportement normal. Si le pipeline levait une erreur, il échouerait tous les week-ends, et les vraies alertes seraient noyées dans de fausses alertes.

En revanche, « vide » n'est normal que si le jour n'était pas censé être publié. Le client d'ingestion devra distinguer plusieurs cas (conception prévue pour l'étape 3, pas encore codée) :

| Cas | Traitement prévu |
|---|---|
| 200 avec données | ingestion normale |
| 200 vide ou 404 « No results found », un week-end ou un jour de fermeture TARGET | « pas de publication » : on journalise et le run est un succès |
| 200 vide ou 404 un jour ouvré, après l'heure de publication | anomalie : retry plus tard, puis alerte |
| 400 | erreur dans ma requête : échec immédiat, pas de retry |
| 5xx, timeout, 000 (pas de connexion) | erreur technique : retry avec délai croissant, puis échec. Jamais interprété comme « pas de publication » |

**Écart à éclaircir :** la [page Status codes de l'API](https://data.ecb.europa.eu/help/api/status-codes) annonce un **404 « No results found »** quand aucune donnée ne correspond à la requête, alors que j'ai observé un **200 vide** pour le samedi. Tant que l'écart n'est pas compris, le client accepte les deux comme « aucune donnée ». La relance du 1er décembre devrait aider à trancher.

## 4. Sens du taux

**Observé** pour la série `EXR.D.USD.EUR.SP00.A` le 13 novembre 2026 : OBS_VALUE = 1.1052, UNIT = USD, TITLE = « US dollar/Euro ECB reference exchange rate ».

**1 EUR = 1,1052 USD.** `UNIT = USD` indique que la valeur est un nombre de dollars. Le dénominateur de la série est l'euro (`CURRENCY_DENOM = EUR` dans la clé), donc 1,1052 est le nombre de dollars pour 1 euro. C'est cohérent avec la [page des taux de référence de la BCE](https://www.ecb.europa.eu/stats/eurofxref), qui cote toutes les devises contre l'euro comme devise de base.

Pour convertir 100 USD en euros, on **divise** par le taux :

```
montant_eur = montant_usd / rate = 100 / 1.1052 ≈ 90,48 EUR
```

Contrôle de bon sens : 1 EUR vaut plus que 1 USD, donc 100 USD doivent donner moins de 100 EUR. Dans l'autre sens (EUR → USD), on multiplie.

## 5. Stabilité de la liste des devises

| Date | Devises publiées |
|---|---|
| 13 novembre 2026 | 29 |
| 10 novembre 2005 | 43 (44 lignes moins l'en-tête) |

Une devise disparaît de la liste quand :

- **le pays adopte l'euro** : sa monnaie n'a plus de taux contre l'euro, puisqu'elle n'existe plus ;
- **la BCE suspend la publication** : par exemple, le dernier taux EUR/RUB a été publié le 1er mars 2022, la BCE ne pouvant plus fixer un taux représentatif du marché ([note technique du 2 mars 2022](https://www.ecb.europa.eu/services/using-our-site/technical-updates/html/ecb.technical_update220302.en.html)).

**À faire :** nommer précisément les devises disparues en comparant les deux listes :

```bash
curl -s "https://data-api.ecb.europa.eu/service/data/EXR/D..EUR.SP00.A?startPeriod=2005-11-10&endPeriod=2005-11-10&format=csvdata" | tail -n +2 | cut -d, -f3 | sort > /tmp/2005.txt
tail -n +2 /tmp/exr.csv | cut -d, -f3 | sort > /tmp/2026.txt
comm -23 /tmp/2005.txt /tmp/2026.txt
```

**Conséquences pour `dim_currency` (Gold) :**

- Ne jamais supprimer une devise : les faits historiques y font référence. On garde `first_seen` et `last_seen`.
- Une nouvelle devise peut aussi apparaître. L'ingestion l'accepte au lieu d'échouer.

**Conséquences pour les tests qualité :**

- On **ne peut pas** exiger 29 devises chaque jour. Le nombre a changé dans le passé, il changera encore, et un backfill sur 2005 échouerait.
- À la place :
  - un jour publié contient au moins 1 ligne ;
  - pas de doublon sur (`rate_date`, `currency_code`) ;
  - `rate > 0` ;
  - comparer la liste du jour à celle du dernier jour publié : une devise qui disparaît ou apparaît déclenche un **avertissement** à vérifier, pas un échec bloquant.

## Limites connues de la source

| Limite | Vérifiée par |
|---|---|
| Publication uniquement les jours ouvrés, sauf les jours de fermeture TARGET. Rien le week-end ni ces jours-là. | [Page des taux de référence de la BCE](https://www.ecb.europa.eu/stats/eurofxref) + mon appel du samedi 14/11 (200 vide) |
| La liste des devises change dans le temps (43 en 2005, 29 en 2026). Pas de taux EUR/RUB depuis le 1er mars 2022. | Mes appels du 10/11/2005 et du 13/11/2026 + [note technique BCE du 2 mars 2022](https://www.ecb.europa.eu/services/using-our-site/technical-updates/html/ecb.technical_update220302.en.html) |
| Publication vers 16:00 CET. La page de la BCE situe la concertation entre banques centrales vers 14:10 CET, alors que la colonne `TITLE_COMPL` de l'API indique « 2.15 pm (C.E.T.) » : les deux sources de la BCE diffèrent de 5 minutes. Le `last-modified` du 13/11 (14:57 GMT, soit 15:57 CET) est cohérent avec une publication vers 16:00. Conséquence : planifier l'ingestion après 16:30 CET. | [Page des taux de référence de la BCE](https://www.ecb.europa.eu/stats/eurofxref) + colonne `TITLE_COMPL` + en-tête `last-modified` du 13/11 |
| Ce sont des taux de **référence**, publiés à titre d'information. La BCE déconseille fortement de les utiliser pour des transactions. Ils conviennent pour de l'analyse et du reporting, pas pour valoriser un paiement réel. | [Page des taux de référence de la BCE](https://www.ecb.europa.eu/stats/eurofxref) |
| Réponse « aucune donnée » ambiguë : la doc annonce un 404, j'ai observé un 200 vide. Le client doit gérer les deux. | [Page Status codes de l'API](https://data.ecb.europa.eu/help/api/status-codes) + mon appel du 14/11 |

## Sources

- [ECB Data Portal, API data](https://data.ecb.europa.eu/help/api/data)
- [ECB Data Portal, Status codes](https://data.ecb.europa.eu/help/api/status-codes)
- [BCE, Euro foreign exchange reference rates](https://www.ecb.europa.eu/stats/eurofxref)
- [BCE, suspension du taux de référence du rouble (2 mars 2022)](https://www.ecb.europa.eu/services/using-our-site/technical-updates/html/ecb.technical_update220302.en.html)
