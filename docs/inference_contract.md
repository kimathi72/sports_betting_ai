# Rails ↔ FastAPI inference contract

Status: **AGREED TARGET — awaiting Kilo implementation of `/predict/from-history`.**
Owner of the ML side: Kilo. Owner of the Rails side: this agent.

## Why a second endpoint

The ML service currently exposes only `POST /predict/{market}`, which accepts 17
**flat, pre-computed** features. Rails holds canonical match and history data, not
features, and the agreed architecture is:

> Rails retrieves and supplies canonical match/history records. Python owns
> authoritative feature engineering and model inference.

`ml/app/features.py::compute_match_features(match, history)` already implements
exactly that — it takes a match plus prior matches, filters anything at or after
kickoff, and returns the ordered 17-feature vector. It is not currently reachable
over HTTP.

Computing the 17 features in Ruby instead would duplicate that formula in two
languages. The temporal-leakage guard (strict `kickoff_at <`, completed only,
both scores present) would then exist in two places and could silently diverge.
**Rails will not implement the feature formulas.**

## Request (Rails → FastAPI)

`POST {ML_SERVICE_URL}/predict/from-history/{market}`

```json
{
  "market": "1x2",
  "match": {
    "id": 123,
    "kickoff_at": "2026-08-20T15:00:00Z",
    "home_team_id": 7,
    "away_team_id": 9
  },
  "history": [
    {
      "id": 456,
      "kickoff_at": "2026-08-10T15:00:00Z",
      "status": "completed",
      "home_team_id": 7,
      "away_team_id": 11,
      "home_score": 2,
      "away_score": 1
    }
  ],
  "competition": "Premier League",
  "season": "2026/27"
}
```

Guarantees Rails makes about `history` (already enforced and tested by
`Predictions::MatchHistory`):

- every entry has `kickoff_at` **strictly before** `match.kickoff_at`
- every entry is `status: "completed"` with both scores present
- the target match is excluded
- only matches involving either club are included
- bounded to ≤10 per club and ≤40 total

Python should still apply its own defensive filter. The two guards are
intentional belt-and-braces, not redundancy to remove.

## Response (FastAPI → Rails)

```json
{
  "match_id": 123,
  "market": "1x2",
  "probabilities": { "H": 0.5, "D": 0.3, "A": 0.2 },
  "selection": "H",
  "model_version": "v0.2.0",
  "trained_at": "2026-08-01T00:00:00Z",
  "predicted_at": "2026-08-19T10:00:00Z"
}
```

Canonical outcome keys per market:

| market | outcomes |
| --- | --- |
| `1x2` | `H`, `D`, `A` |
| `over_under_2.5` | `over`, `under` |
| `btts` | `yes`, `no` |
| `double_chance` | `1x`, `x2`, `12` |

`double_chance` is **derived by Rails** from a stored 1X2 prediction and is not
requested from the ML service.

Rails rejects the response and persists nothing when:

- `match_id` does not equal the requested match
- `market` does not equal the requested market
- a required outcome key is missing, or an unexpected key is present
- any probability is outside `[0, 1]`
- the distribution does not sum to 1 within `1e-5`
- `model_version` is blank

## Blockers

1. `/predict/from-history/{market}` does not exist yet (Kilo).
2. `ml` binds `127.0.0.1` and the container cannot import `ml.app.main`
   (`docker-compose.yml` / `ml/Dockerfile`, shared — needs coordination).
3. No loadable artifact: `ml/artifacts/` holds only `model.joblib`, while the
   code expects `model_1x2.joblib`; the existing file fails to deserialize under
   the container's scikit-learn.
