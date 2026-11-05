# Sports Betting AI — Development Handover

**Last updated:** 2026-11-02
**Status:** Mobile compiles and tests are green (`tsc` 0 errors, Jest 128/128); Android bundle exports. Manual device testing is the next phase and has not been done.

This file is the running record. It is append-only by section: earlier reports below
are kept, not rewritten, so the history of what was claimed and what was verified
stays visible.

---

## 1. Recovery report (start of this session)

A prior session was interrupted mid-way through the data/ML assignment; a second
agent then explored the mobile app without producing working screens. The state
below was verified against the repository, database, containers and test suites —
not taken from earlier reports.

| Area | Actual state | Evidence | Outstanding at audit time |
|---|---|---|---|
| Git | Branch `main`, uncommitted work including Rails, ML and new mobile files. No commits or pushes made this session. | `git status` | Nothing — committing is deliberately not done |
| Docker | postgres, redis, web, sidekiq, ml containers defined; ml rebuilt and healthy | `docker compose ps` | — |
| PostgreSQL | 11 competitions, 12 seasons each, 39,540 matches (39,259 completed) | `psql` counts | — |
| Historical data | 2016/17–2026/27 for 11 European leagues via football-data.co.uk | `data/manifests/*.yml` | UEFA competitions: no reliable historical source |
| ESPN integration | Client, adapter and synchroniser present; current-season fixtures only | `Import::EspnClient` etc. | Historical backfill via ESPN is not viable |
| Downloader / storage | Host-mounted `data/raw`, 41 specs, idempotent re-download | `ls data/raw`, specs | — |
| Rails API | competitions/seasons/teams/matches/predictions/sync-status | controller specs | Competition names/countries were placeholders (fixed, §2) |
| FastAPI / ML | 283 tests passing; market-specific artifacts published | `pytest` | — |
| Market models | 1X2, O/U 2.5, BTTS, derived Double Chance, Correct Score | `artifacts/*.meta.json` | Goal model is weaker than the classifiers on 1X2 |
| Tests | Backend 884 examples / 0 failures; ML 283 passing; mobile 128 passing | suite runs | — |

**Defect found and fixed during recovery:** `app/services/import/api_football_reconciler.rb`
defined a module-level `Import::Result` struct, which shadowed `Import::Result` (the
import-run value object) whenever that file autoloaded first. The whole backend suite
was red (138 failures) in some orders and green in others depending on file load
order. The struct is now nested inside the reconciler class.

## 2. Competition identity defect (fixed)

Competitions were stored as `"football_data competition E1"` with a null `code` and
null `country`. That is an internal import key leaking into the API and the app.

- New `CompetitionCatalogue` (`backend/app/services/competition_catalogue.rb`) maps
  every verified division code to a name, country and region.
- The resolver now names a competition from the catalogue at creation time and
  adopts an existing catalogue-named row instead of duplicating it.
- `CompetitionCatalogue.backfill!` repaired the live rows: all 11 competitions now
  have a readable name, a country and a code.
- `GET /api/v1/competitions` gained `region`, `seasons`, `current_season`,
  `match_count` and `completed_count` (additive; existing fields unchanged). The
  mobile region filter groups by the server's own regions instead of a hardcoded
  country list that had drifted.

Verified result:

```
E0 Premier League      England     11 seasons  4160 matches
E1 Championship        England     11 seasons  6045 matches
...
```

### Model source: switched the default to the goal distribution

The 1X2 classifier has a better held-out log loss (0.999 vs 1.011 on the untouched
test window, baseline 1.075) — but it is not usable as a price. Measured on 2,000
held-out fixtures it assigns a mean maximum probability of **0.977**, gives P(draw) a
mean of roughly **0**, and returns 1.0/0.0/0.0 for an ordinary league fixture
(Man City v Fulham came back 0.999/0.0005/0.0007). The draw class is effectively
never predicted.

The goal distribution returns 0.576 / 0.173 / 0.251 for the same fixture, and because
every market is a view of one scoreline grid, Over/Under, BTTS, Double Chance and
Correct Score agree with the 1X2 by construction:

```
1x2             {H: 0.57603, D: 0.17271, A: 0.25126}
double_chance   {1X: 0.74874, X2: 0.42397, 12: 0.82729}    1X == H + D exactly
over_under_2.5  {Over: 0.83743, Under: 0.16257}
btts            {Yes: 0.78593, No: 0.21407}
correct_score   {2-1: .0704, 3-1: .0648, 2-2: .0648, 3-2: .0596, 1-1: .0490, 1-2: .0469}
```

`POST /predict/from-history/{market}` now defaults to `source=goal_model`; the
classifier remains one query parameter away (`source=classifier`) and
`Predictions::MarketPredictor.new(source: "...")` exposes it on the Rails side.
This is a documented, reversible default, not a silent preference.

**Known limitation:** neither model is strong. Accuracy is ~51% on 1X2 against a
46% majority baseline, and Correct Score hits the exact score ~9% of the time. These
are honest baseline-level numbers from ~34,000 training fixtures, not a validated
edge. No profitability claim is made anywhere: there is no odds data in the
project, so none can be substantiated.

## 4. MVP verification (end to end)

| Check | Result |
|---|---|
| `docker compose ps` | web, postgres, redis, sidekiq, ml all up |
| `GET /api/v1/competitions` | 11 competitions, all with name, country, code, region, seasons |
| `GET /api/v1/seasons?competition_id=N` | real season list per competition |
| `GET /api/v1/matches?season_id=N` | 39,540 matches total, 39,259 completed |
| `GET /api/v1/matches?season_id=6&status=scheduled` | upcoming Premier League fixtures |
| Rails → ML 1X2, Double Chance, O/U 2.5, BTTS, Correct Score | all 5 succeed on match 4357 |
| Double Chance consistency | 1X = 0.74874 = H + D (exact) |
| Backend suite | 899 examples, 0 failures, 1 pending |
| ML suite | 283 passed |
| Mobile `tsc` | 0 errors |
| Mobile `jest` | 128 passed |

## 5. Outstanding work (explicitly not done)

- **Live matches.** The backend has no in-play data source; the Live screen must
  show an honest empty state rather than a fake ticker.
- **League table.** No standings table is derived from results yet; the screen needs
  a real computation or an explicit "not available" state.
- **Predictions list screen and Profile/worldlist.** Existing Profile/Settings and
  System Status are preserved; the saved-selection experience is not built.
- **Team crest coverage.** 205 of 331 clubs have a verified crest; the rest render a
  monogram. ESPN does not publish lower-division squads.
- **UEFA competitions.** ESPN has no usable historical archive, so the Champions
  League is not in the dataset even though the app could display it.
- **Classifier quality.** Log loss is above the goal model's baseline and the model
  is overconfident; it needs recalibration (or a different algorithm) before it can
  be a default.

## 3. Mobile implementation (in progress)

The mobile app had ~3,100 lines of scaffolding, real API hooks and types, but **did
not compile** (`tsc` failed) and its asset modules pointed at `placeholder.com`
(an external service that returns 404s) — crests and logos would have been broken
images for every team.

### Done
- **Design tokens** — palette replaced with the required navy identity
  (`#071321` background, `#0B1B2D` surface, `#2478F2` primary, `#20C997` analytics
  green, `#F15B64` live red), radii and spacing aligned to the spec.
- **Team crests** — `src/assets/teamCrests.ts` holds verified crest URLs for 205 of
  331 clubs, resolved from ESPN's public team endpoint and fetched to confirm
  HTTP 200. `TeamCrest` falls back to an initials monogram (never another club's
  badge, never an emoji) for clubs ESPN does not publish.
- **Competition logos** — `src/assets/competitionLogos.ts`, keyed by catalogue code,
  all 12 verified.
- **Country flags** — `src/assets/flags.ts` via flagcdn; England/Scotland use the
  sub-national flags rather than the Union Jack.
- **Components** — `TeamCrest`, `CompetitionLogo`, `CountryFlag`, `CompetitionCard`,
  `PressableCard`, `FilterChips`, plus a `@/components` barrel.
- **Competitions screen** — real search over name/country/region, region chips
  derived from the API, live match counts, pull-to-refresh, empty/error states.
- **Competition Details** (`app/competitions/[id].tsx`) — identity header, real
  season selector, All/Results/Upcoming tabs over one season query.

### Tests
| Suite | Result |
|---|---|
| `npx tsc --noEmit` | 0 errors |
| `npx jest` | 128 passed, 11 suites |
| Backend `rspec` | 884 examples, 0 failures |
| ML `pytest` | 283 passed |

### Next
Match Details, Live, League Table, Predictions, Profile, and the Home screen wiring
against the extended competition payload.


---

## 6. End-to-end verification session (2026-11-02)

Hands-on verification of the running stack. Every result below was produced by an
actual command; nothing is inferred from reading code.

### 6.1 Service and health

| Check | Command | Result |
|---|---|---|
| Containers | `docker compose ps` | postgres, redis, web, sidekiq, ml — all up |
| Rails liveness | `GET /api/v1/health` | HTTP 200 |
| Rails readiness | `GET /api/v1/ready` | HTTP 200, database ok |
| Rails `/up` | `GET /up` | HTTP 200 |
| Sync status | `GET /api/v1/sync/status` | HTTP 200 |
| FastAPI liveness | `GET /health` (port 8000) | HTTP 200 `{"status":"ok"}` |
| FastAPI readiness | `GET /ready` | HTTP 200, `1x2: ok`, `goal_distribution: ok` |

Correction to the test plan: `/health` and `/ready` do not exist on Rails — the real
endpoints are `/api/v1/health`, `/api/v1/ready` and `/up`. No route was added.

### 6.2 Prediction API contract (established, not assumed)

- `POST /api/v1/predictions` with `{"match_id": N, "markets": [...]}` **generates**
  and stores predictions. Returns `{"match_id", "generated_at", "predictions": [...]}`.
- `GET /api/v1/predictions/:match_id` **retrieves** stored predictions.
- `GET /api/v1/predictions?limit=` returns the collection.
- `/api/v1/matches/4357/predictions` is **not** a route — per-match predictions live
  under `/predictions/:match_id`. The mobile client already uses this.

### 6.3 Match 4357 (Manchester City v Fulham, scheduled, Premier League)

Found in the `?season_id=6&limit=400` collection (there is no single-match route).
Generated all five markets with HTTP 200:

| Market | Probabilities | Checks |
|---|---|---|
| `1x2` | H 0.57603 · D 0.17271 · A 0.25126 | sums to 1 |
| `double_chance` | 1X 0.74874 · X2 0.42397 · 12 0.82729 | each equals the 1X2 sums exactly (delta 0.00000000) |
| `over_under_2.5` | Over 0.83743 · Under 0.16257 | sums to 1 |
| `btts` | Yes 0.78593 · No 0.21407 | sums to 1 |
| `correct_score` | 6 top lines, total 0.3763 | truncated view, ≤ 1, in range |

All probabilities in `[0,1]`. No model-quality or profitability claim is implied by
a successful response.

### 6.4 Error handling (live)

| Request | Result |
|---|---|
| `GET /api/v1/predictions/999999` | 404, honest body |
| `POST` with market `teleportation` | 400, unsupported market |
| `POST` without `markets` | 400, validation message |

### 6.5 Rails → FastAPI integration

`ML_SERVICE_URL` is set in the web container and `http://ml:8000/health` answers from
inside it. Predictions are computed only when Rails calls the ML service; Rails never
computes a probability. The mobile app has **zero** references to port 8000 or to
FastAPI and targets `EXPO_PUBLIC_API_BASE_URL` (Rails) only.

### 6.6 Mobile

| Check | Result |
|---|---|
| `npx tsc --noEmit` | 0 errors |
| `npx jest` | 128 passed, 11 suites |
| Metro bundle (`expo-router/entry`, android, dev) | HTTP 200, 8.6 MB, compiles |
| New screens present in bundle | Competition Details, Home hero, crest fallback, match head-to-head |
| `npx expo-doctor` | run; see log |

**Device/emulator: NOT TESTED.** No Android SDK or adb is installed on this host and
no AVD exists, so no device-level test was performed. The bundle compiling and the
API contract being exercised by the real client code is the strongest evidence
available here; it is not the same as a device run.

### 6.7 Defect found and fixed

**`Prediction#most_likely_outcome` lied for non-1X2 markets.** It read the legacy
home/draw/away columns unconditionally; every non-1X2 market leaves those at
0/0/1, so a correct-score prediction reported `most_likely_outcome: "away"` with
1.0/0.0/0.0. The API serves that field, so the app could display a confident "away"
for a market about scorelines.

- Test written first (`spec/models/prediction_markets_spec.rb`) — 2 failures.
- Fix: the accessor returns `nil` unless `market == '1x2'`.
- Files: `app/models/prediction.rb`, `spec/models/prediction_markets_spec.rb`.
- Verified on the live API: all non-1X2 markets now return `most_likely_outcome:
  null`; 1X2 still returns its favourite.

### 6.8 Live Matches and League Table

The database contains only `completed` and `scheduled` statuses — **zero** live
matches — and no standings table is derived from results. Neither screen exists in
the app yet, so nothing can display fabricated live data. They remain the top
unbuilt screens.

### 6.9 Tests run after the fix

| Suite | Result |
|---|---|
| Backend `rspec` (full) | **902 examples, 0 failures, 1 pending** |
| Models + API requests | 145 examples, 0 failures |
| Mobile `jest` | 128 passed |
| Mobile `tsc` | 0 errors |

### 6.10 Remaining blockers

1. **No device run.** Install the Android SDK / create an AVD, then
   `npx expo start --android` with `EXPO_PUBLIC_API_BASE_URL` pointing at a
   reachable host (not `localhost` from an emulator — `10.0.2.2` for AVD).
2. **Live matches** need a provider with in-play data; none is integrated.
3. **League table** needs a standings computation from results; not built.
4. **Predictions list screen** exists but has not been exercised against a large
   collection on a device.

## 7. Mobile TypeScript debugging session (2026-11-02, morning)

Focused stabilisation of `mobile/` before manual device testing. Scope was limited to
mobile compilation and test health. Nothing in `backend/`, `ml/`, `data/`, Docker
volumes, `.env` files or Git history was touched; no commit or push was made.

### 7.1 What was actually wrong

The previous entry's "`npx tsc --noEmit` 0 errors" / "128 passed" was **stale**. On
the current working tree:

- `npx tsc --noEmit` → **15 errors** (exit 2).
- `npx jest` → **6 failed, 122 passed** (11 suites, 1 failing).

No `*.tsbuildinfo` existed, so this was not a stale incremental cache. There were no
editor-only diagnostics to separate: every `tsc` error was real, and 6 of them were
corroborated by failing tests.

### 7.2 Root causes (four, not fifteen)

**RC-1 — `@testing-library/react-native` 14 made `render`/`fireEvent` async.
(8 type errors, 6 test failures.)** `package.json` pins
`@testing-library/react-native@^14.1.0`, whose `render()` returns
`Promise<RenderResult>` and whose `fireEvent()` returns `Promise<undefined>`. It was
upgraded but `__tests__/components/assets.test.tsx` still used v12-style synchronous
calls, so `({ getByTestId }) = render(...)` destructured a `Promise`. Every other
suite in the repo already awaited `render`; this one file did not. **This was not a
typing problem to suppress — the tests really were asserting against an unrendered
component**, which is why 6 of them failed at runtime.

A second, subtler instance surfaced only after `render` was awaited: the
"image fails to load" test called `fireEvent(...)` without awaiting it, so the
`setFailed(true)` state update had not been flushed when the fallback was queried
(`Unable to find an element with testID: team-crest-fallback-Arsenal`). Both calls
are now awaited.

**RC-2 — `spacing` imported from `@/theme/theme`, which never exported it.
(1 error).** `app/(tabs)/competitions/index.tsx` does
`import { layout, spacing } from "@/theme/theme"`. `theme.ts` imported `spacing`
from `tokens.ts` but never re-exported it, so the name resolved to nothing.

**RC-3 — colour keys invented at the two call sites. (2 errors).** Two components
referenced theme slots that do not exist in the design system:

- `CompetitionCard` read `theme.colors.effectiveWarnings.warning` — not an MD3
  property. The intended colour, and the one every other screen uses
  (`app/(tabs)/settings/system.tsx`, `settings/index.tsx`), is `theme.app.warning`.
- `CountryFlag` read `palette.surfaceSecondary ?? palette.surfaceElevated`. There is
  no `surfaceSecondary` token; `palette.backgroundSecondary` is the secondary surface.
  The `??` looked defensive but is dead weight on a non-optional missing key — it
  compiled the wrong thing, it did not protect anything. Replaced with the token that
  is actually meant (`surfaceElevated`, the elevated control surface a flag sits on).

**RC-4 — unused bindings left behind by the automatic JSX runtime. (3 errors).**
`noUnusedLocals`/`noUnusedParameters` are on; `CompetitionLogo` and `CountryFlag`
still had `import React` (unused since `jsx: "react-jsx"`), and `CountryFlag`
imported `radius` without using it. `TeamCrest` had already been cleaned; these two
were missed.

One more genuine mismatch, same family as RC-1 but not caused by it:
`app/competitions/[id].tsx` declared `const season: Season | undefined` while
`pickDefaultSeason()` returns `Season | null`. Under `strict`, `null` is not
assignable to `undefined`. The annotation was wrong, not the function: `null` *is*
the "no season" signal this screen renders an empty state for.

### 7.3 Files changed (6)

| File | Change | Why |
|---|---|---|
| `mobile/__tests__/components/assets.test.tsx` | `await` on 6 `render()` calls and 1 `fireEvent()`; added a comment on the async contract | RC-1 |
| `mobile/src/theme/theme.ts` | `export { spacing }` (same object as `tokens.spacing`, not a copy) | RC-2 |
| `mobile/src/components/CompetitionCard.tsx` | `theme.colors.effectiveWarnings.warning` → `theme.app.warning` | RC-3 |
| `mobile/src/components/CountryFlag.tsx` | dropped unused `React` + `radius` imports; `palette.surfaceSecondary ?? …` → `palette.surfaceElevated` | RC-3, RC-4 |
| `mobile/src/components/CompetitionLogo.tsx` | dropped unused `React` import | RC-4 |
| `mobile/app/competitions/[id].tsx` | `Season \| undefined` → `Season \| null` | type mismatch |

No `any`, no type assertions, no `@ts-ignore`/`@ts-nocheck`, no lint suppression, no
dependency change, no screen or feature removed, no data mocked. `app/(tabs)/competitions/index.tsx`
was **not** edited — the defect was in `theme.ts`, so the fix was made there rather
than weakening the import.

### 7.4 Commands executed and actual results

```
cd mobile
npx tsc --noEmit        # before: 15 errors, exit 2
npx jest               # before: 6 failed / 122 passed, 1 suite failed
npx tsc --noEmit        # after:  exit 0, 0 errors
npx jest               # after:  128 passed, 11 suites passed
npx expo-doctor        # 19/20 checks passed, 1 failed (patch drift, see 7.5)
npx expo export --platform android --output-dir /tmp/sb_android_export
                       # exit 0 — entry-*.hbc 3.7 MB, 0 warnings
```

The export directory was written to `/tmp` and removed afterwards; no build output
was added to the repository.

### 7.5 Remaining issues

1. **Expo Doctor: 1 of 20 checks still fails — patch-level version drift.** Expected
   vs found: `expo ~58.0.22` vs `58.0.21`; `expo-router ~58.0.29` vs `58.0.28`;
   `@expo/metro-runtime ~58.0.16` vs `58.0.15`. All three are a single patch behind
   the SDK 58 pins.

   **Deliberately not changed this session.** These are not source errors: the app
   compiles, all 128 tests pass and the Android bundle builds on the installed
   versions. The project's workflow ships a custom `expo` (non-Expo Go) build, which
   does not depend on the Expo Go client version those warnings are aimed at, and
   `expo-router` has known runtime behaviour changes even in patch releases
   (`58.0.29` alters expiry handling for development links). Changing three packages
   and rewriting `package-lock.json` was neither required by an error nor something
   to do silently alongside a typing cleanup. Verified that all three target
   versions exist on npm, so the upgrade is available when you want it.

   If you want Doctor fully green, the smallest safe change is:
   `npx expo install --fix`, then re-run `npx tsc --noEmit`, `npx jest` and
   `npx expo export --platform android` to confirm nothing moved.

2. **Jest logs an `act()` warning and a "worker process failed to exit
   gracefully"** notice from the `apiHooks` suite (TanStack Query timers). This was
   present before this session; the suite passes. It is teardown hygiene, not a
   failure, and was out of scope here.

3. Catches previously listed in §5/§6.10 (live matches, league table, no device
   run) are unchanged.

### 7.6 Next: launch and test manually

Start the backend first, then Expo with an address the device can actually reach.

```bash
# 1. backend + ML stack
cd ~/workshop/sports_betting_ai
docker compose ps          # web, postgres, redis, sidekiq, ml should be up
docker compose up -d       # only if something is down
curl -s http://localhost:3000/api/v1/health
curl -s http://localhost:8000/health

# 2. point the app at a reachable host  (mobile/.env)
#    Android emulator (AVD):   EXPO_PUBLIC_API_BASE_URL=http://10.0.2.2:3000
#    physical device, same LAN: EXPO_PUBLIC_API_BASE_URL=http://<your-LAN-IP>:3000
#    localhost only works for the web target.

# 3. start Metro
cd mobile
npx expo start
```

Then, on the device: press `a` for the Android emulator, or scan the QR code with
Expo Go / the development build.

**Walk these screens, in this order** (each is backed by a real endpoint):

1. Home — hero plus competition payload (`GET /api/v1/competitions`).
2. Competitions — the region chips must only list regions that have data; the search
   box should match name, country and region.
3. Competition Details — open a league, switch season chips, switch
   All/Results/Upcoming (one query, client-side tab narrowing).
4. Match Details — open a scheduled fixture and check the five market tabs
   (`POST /api/v1/predictions`); correct-score must show scorelines, and no
   non-1X2 market may display a "most likely outcome" of home/draw/away.
5. Predictions and Performance — list rendering.
6. Settings + System Status — API reachability and sync status.

Useful while testing:

```bash
npx tsc --noEmit && npx jest        # keep the two green checks green
docker compose logs -f web          # watch the requests the device makes
```

**Not tested and not claimed:** no Android SDK/AVD or `adb` is installed on this
host, so nothing here proves behaviour on a device or emulator. The evidence is a
zero-error type check, a green Jest suite, a passing Expo Doctor on all checks except
the version pins, and a compiling Android Hermes bundle.

## 8. Fixture data-integrity investigation (2026-11-02, read-only)

**Status: INVESTIGATION COMPLETE. REPAIR BLOCKED. No fixtures were deleted, no
import ran, nothing was committed.**

This section corrects several claims made in the previous (unpublished) report.
Where the two disagree, this section is the evidence.

### 8.1 Incident summary

Two separate incidents were reported as one. They are different in kind and must
not be repaired by the same mechanism.

| # | Incident | Rows | Kind |
|---|---|---|---|
| A | Championship (`eng.2`) fixtures written into the Premier League's 2026/27 season | **139** | Wrong competition. Real fixtures, wrong league. |
| B | Deputy Premier League (`eng.1`) fixtures written into the same season | **297** | Real E0 fixtures the dataset was missing. |
| C | Scottish Premiership (`sco.1`) fixtures written into an older SC0 season | **36** | Wrong season, right competition. |

A and B were produced by the same run of `espn:discover`; the split is visible in
the ESPN event ids — `40187xxxxxx` events are served by `eng.1`, `40188xxxxxx` by
`eng.2`. Verified against the live provider, not inferred.

### 8.2 What is confirmed

1. **The total reconciles exactly.** The sync ledger records `created` per run:

   ```
   eng.1: 28 created   eng.2: 408 created   total 436
   ```
   `39,540 + 436 = 39,976`. There is no unexplained remainder.

2. **Team mappings are not wrong.** Every mismatch found was a competition or
   season assignment, never a team mapped to the wrong club.

3. **No duplicates were introduced.** For all 436 new rows, zero share
   `(home_team, away_team, date)` with a pre-existing row in the same season.

4. **The 29 "completed" rows are genuine results**, not fabricated ones. Each
   matches ESPN's score exactly (10 Premier League results from 31 Oct – 1 Nov
   2026). They are the reason the app showed results only to 29 October and then
   nothing until 21 November: the 31 Oct/1 Nov round had never been imported.

5. **The 17 additional E0 completed matches are legitimate.** They are real
   played fixtures recovered from ESPN, not corruptions.

6. **No existing rows were updated or reassigned.** `updated` was 0 across every
   run in the ledger; all 436 are inserts.

7. **The defect is the season lookup, and it is still live.** `espn:discover`
   resolved the target season with `Season.find_by(name: label)`. Season names are
   not unique across competitions, so it returned whichever "2026/27" row came
   first — always the Premier League's. `espn:ingest` had the same bug.

8. **Completed results were affected, not only fixtures** — a Championship match
   can arrive already played and be stored as a completed E0 result.

### 8.3 What is uncertain

- **Whether A and B can be separated row by row without the provider.** The
  event-id prefix does separate them, but the prefix rule has been verified on a
  sample, not on all 436 rows. Any repair must re-derive it per row from ESPN.
- **Which SC0 season each of the 36 Scottish rows belongs to.** They sit outside
  the season they are filed under; the correct target has not been determined.
- **Whether other providers are affected.** API-Football and football-data writes
  go through the same reconciler but a different entry point; not audited here.

### 8.4 Why `Sync::ForeignFixtureBleed` is unsafe and cannot work

Measured against the live database (read-only, candidate selector only):

```
candidates returned:            0
rows the rule inspects:       687
every one rejected because:   inside_season_window = 687
```

All 687 rows are rejected by the **date-window** condition alone. The rule is not
overly strict — it tests the wrong property. The contamination is *inside* the
season window, because these are genuinely 2026/27 fixtures filed under the wrong
competition. No date-based rule can ever find them.

Two further defects make it unsafe even if the date test were removed:

- **Its spec does not describe the incident.** `foreign_fixture_bleed_spec.rb`
  currently reports 8 examples, 2 failures. The two passing "selection" examples
  assert a rule that matched nothing, so the suite would have given false
  confidence.
- **`fit_live_data` was never true.** The previous report claimed the rule had
  been validated against live rows. It was validated against synthetic rows only.

**It must not be run.** `call(dry_run: false)` deletes matches.

### 8.5 Why `Sync::EspnLeagueSeason` is not active

The class is declared as `class` but uses `module_function`. Ruby raises
`NoMethodError: undefined method 'module_function'` at load time. Consequence —
verified — **the entire backend suite does not start**:

```
0 examples, 0 failures, 1 error occurred outside of examples
```

Any statement that this mapping is "fixed and tested" is wrong until this is
corrected. The correction is one word (`class` → `module`) plus moving
`module_function` below the method definitions, and it is intentionally **not**
made in this read-only session.

### 8.6 Safety status of background writes

| Check | Result |
|---|---|
| `sidekiq` container | not running |
| cron entries registered | **0** (`sync:schedule:list` reports nothing registered) |
| `sync_runs` with `status='running'` | 0 |
| Full-season discovery job registered | no — nothing can enqueue ESPN writes |

No measure was needed to stop writes: nothing is scheduled and no worker exists to
run a job. Restarting Sidekiq would register `SyncEspnDiscoveryJob`, which would
begin writing — **do not start the worker before §8.7 is decided.**

### 8.7 Recovery plan (proposed, NOT implemented)

**Preserve unconditionally:** all 39,540 original rows, all football-data
provenance, all 4,360 predictions, match 4280.

**Class 1 — correct automatically (evidence: ESPN event-id prefix).**

- The 139 `eng.2` rows in E0/2026/27 → move to E1/2026/27 (`competition_id` and
  `season_id` both change; teams, scores and ESPN identifiers unchanged).
- The 297 `eng.1` rows are correct where they are — verify, then leave.

Assignment change, not deletion: it keeps the fixtures, their provider identity and
the predictions that point at them. This is the only class where the evidence is
already sufficient.

**Class 2 — provider verification required.** The 36 SC0 rows: confirm each target
season against ESPN before reassignment.

**Class 3 — manual review.** Any row whose ESPN id resolves to neither league at its
stored date. In the current batch this set is empty after correcting for kickoff
timezone drift, but the check must be rerun at repair time.

**Class 4 — must remain untouched.** All football-data rows; all completed rows
below id 39600; match 4280.

**Quarantine, do not delete.** If any row cannot be classified, set it aside in a
holding table rather than removing it, so the ledger of what happened survives.

**Never:** the current `ForeignFixtureBleed`; any deletion of completed rows; any
`DELETE`/`UPDATE` before a reviewed, reversible migration.

### 8.8 Next steps

1. Fix `EspnLeagueSeason` (`class` → `module`) — without this the suite cannot run
   and no test result below can be trusted.
2. Rewrite `foreign_fixture_bleed_spec.rb` against the actual incident (id prefix),
   or retire the class in favour of the reassignment approach above.
3. Write the reassignment migration with a verified, reversible mapping table.
4. Re-run the full suite; expect the baseline 902 examples that was green
   before these changes.
5. Only then decide whether Sidekiq may be started.

### 8.9 Test results (actual)

| Suite | Result |
|---|---|
| Backend `rspec` (full) | **1 error outside examples — suite does not run** (8.5) |
| `foreign_fixture_bleed_spec` | 8 examples, **2 failures** |
| Balance of the suite | unmeasured, because of the load error |

## 9. ESPN season resolution repair (2026-11-02, code and tests only)

Resolves the defect identified in §8 without touching any football record.
**No fixture was imported, deleted, reassigned or quarantined; no prediction
changed; Sidekiq was not started; nothing was committed.**

### 9.1 Root cause

`Season` is unique on `(competition_id, name)`, never on name alone. Every
competition has a `2026/27`. Both ESPN entry points resolved the target with
`Season.find_by(name: label)`, which returns whichever row the database offers
first — in practice the Premier League's. That is how `eng.2` fixtures were filed
under E0.

The defect had **two independent halves**:

1. the lookup was scoped to a name, not a competition;
2. the slug → competition translation was inverted. `EspnLeagueCoverage::VERIFIED`
   is keyed **CODE => SLUG** (`"E0" => "eng.1"`). Reading it as `VERIFIED[slug]`
   misses every league. This is why the first draft of the new resolver raised
   `UnknownLeague` for `"eng.1"` — a defect introduced while fixing the original.

### 9.2 The resolver (`Sync::EspnLeagueSeason`)

Declared as a **class** (the previous version used `module_function` inside a
`class`, which raised at load and prevented the entire suite from starting).

```
slug --EspnLeagueCoverage.code_for_slug--> code --Competition--> Season (scoped)
```

| Entry point | Behaviour |
|---|---|
| `for_league(slug, label)` | Raises `UnknownLeague` / `UnknownCompetition` / `UnknownSeason` / `AmbiguousSeason` |
| `for_code(code, label)` | Same failures; used when the code is already known |
| `find(code, label)` | Compatibility: returns nil when absent, raises only on ambiguity. Used by the scheduled job, where "no season yet" is an ordinary skip |

`AmbiguousSeason` is raised when two rows share a label within one competition —
choosing one silently is the exact failure mode being removed. `UnknownLeague`
lists the known slugs so the error is actionable.

### 9.3 Both entry points now share one path

| Task | Before | After |
|---|---|---|
| `espn:ingest` | `Season.find_by(name: label)` | `Sync::EspnLeagueSeason.for_league` |
| `espn:discover` | inverted the map by hand, then `.find` | `Sync::EspnLeagueSeason.for_league` |

Both abort with the resolver's message. Neither can fall back to a name-only
lookup. A static spec fails if `Season.find_by(name:` reappears in any ESPN file.

### 9.4 Files changed

| File | Change |
|---|---|
| `app/services/sync/espn_league_season.rb` | Rewritten: class, nested error types, slug→code→season resolution, ambiguity refused |
| `app/services/espn_league_coverage.rb` | Added `code_for_slug` (frozen inverse of `VERIFIED`), `SLUG_TO_CODE` |
| `lib/tasks/espn.rake` | `ingest` and `discover` both use `for_league`; both print the resolved season |
| `app/services/sync/foreign_fixture_bleed.rb` | Removed a duplicated method and the dead hour-based rule left by an earlier edit |
| `spec/services/sync/foreign_fixture_bleed_spec.rb` | Aligned to the single implemented rule |

New specs: `spec/services/sync/espn_league_season_spec.rb` (11), 
`spec/services/espn_league_coverage_spec.rb` (6), 
`spec/lib/tasks/espn_season_resolution_spec.rb` (5).

### 9.5 Verification (actual output)

```
rspec spec/services/sync/espn_league_season_spec.rb spec/services/espn_league_coverage_spec.rb
  17 examples, 0 failures

rspec spec/lib/tasks/espn_season_resolution_spec.rb
  5 examples, 0 failures

rspec spec/services/sync/ spec/services/import/espn_*_spec.rb spec/jobs/sync_espn_discovery_job_spec.rb
  0 failures

rspec                      # full backend suite
  966 examples, 0 failures, 1 pending
```

The pending example is `Match season windows preserves the identity of match 4280`
— it skips when row 4280 is absent, which is true of the **test** database. It is
a designed skip, not a failure.

Affirmative coverage from the run:

```
season: E1 2026/27 (season_id=2858)                                    <- ingest, eng.2
Cannot ingest "eng.99" into "2026/27": not a mapped ESPN league ...   <- unknown league
Cannot discover "sco.1" in "2027/28": competition SC0 ... has no
  season named "2027/28"                                              <- Scottish case
```

### 9.6 Data integrity

Database: **`sports_betting_ai_development`** (Postgres). The test suite runs
against a separate `sports_betting_ai_test` and does not touch it.

| Metric | Before | After |
|---|---|---|
| matches | 39,976 | **39,976** |
| predictions | 62 | **62** |
| completed | 39,288 | **39,288** |
| fingerprint | `09e9adb086a2…` | **`09e9adb086a2…`** |

Unchanged. No match, season, competition or prediction row was written.

Correction to §8: predictions total **62**, not 4,360. §8 overstated it.

### 9.7 Safety state

| Check | Result |
|---|---|
| `sidekiq` container | not running (not started in this task) |
| cron entries registered | 0 |
| `sync_runs` running | 0 |
| ESPN tasks executed | none — only stubbed in specs |

### 9.8 Remaining blockers for fixture recovery

The mapping defect is fixed, but **recovery is still blocked and unauthorised**:

1. **139 Championship fixtures remain filed under E0.** The resolver prevents new
   writes; it does not repair existing rows. Requires an approved reassignment.
2. **`Sync::ForeignFixtureBleed` must not be run.** It identifies rows by
   "completed with a future kickoff" and is **not** a validated classifier for
   this contamination — those rows are scheduled fixtures inside the season
   window. It remains in the tree only as documented dead weight and should be
   retired, not used.
3. **36 Scottish fixtures** still have unresolved season assignments.
4. **`api_football.rake` still contains a `Season.find_by(name:`** lookup. Not an
   ESPN path, so out of scope here, but the same class of defect and it should be
   audited before that provider is used.

## 10. Coverage audit, API-Football fix, detector retirement, mobile seasons (2026-11-02)

Continues §8–§9. **No fixture was imported, deleted or reassigned; no prediction
changed; Sidekiq was not started.** Database verified identical before and after.

### 10.1 Upcoming-fixture coverage (verified)

Only **E0** has scheduled fixtures. All eleven competitions have current-season
history, so "has history" and "has upcoming fixtures" are independent facts.

| Code | Competition | Completed | Scheduled | ESPN feed | ESPN team mappings |
|---|---|---|---|---|---|
| E0 | Premier League | 4,289 | **688** | yes | complete |
| E1 | Championship | 5,661 | 0 | yes | 24 (approved) |
| SC0 | Scottish Premiership | 1,482 | 0 | yes | **0** |
| SP1 | La Liga | 3,800 | 0 | yes | **0** |
| D1 | Bundesliga | 3,060 | 0 | yes | **0** |
| I1 | Serie A | 3,800 | 0 | yes | **0** |
| F1 | Ligue 1 | 3,420 | 0 | yes | **0** |
| N1 | Eredivisie | 3,060 | 0 | yes | **0** |
| B1 | Belgian Pro League | 3,100 | 0 | yes | **0** |
| P1 | Primeira Liga | 3,060 | 0 | yes | **0** |
| T1 | Super Lig | 3,060 | 0 | yes | **0** |

**Root cause of the gap: missing team mappings, not a missing feed.** Every slug
returns fixtures when sampled. Only E0/E1 have ESPN team identifiers, so the
reconciler rejects every row for the other nine (`rejected`, which is the safe
behaviour — a guessed team identity would corrupt the table).

### 10.2 Unresolved-team analysis (75 of 204 clubs)

Classified by shared-word evidence, not guessed. Nothing was mapped.

| Reason | Count | Example |
|---|---|---|
| Single shared word, different club | 41 | ESPN "Espanyol" vs our "Barcelona" |
| Several clubs share a word | 16 | ESPN "Atletico Madrid" vs "Real Madrid" / "Atletico" |
| No shared word at all | 18 | ESPN "SC Braga" vs our "Braga" variant |

These are **not** resolvable by rule. Mapping them requires a per-club review with
denied-conflict checking; forcing them would be the fabrication this project has
consistently refused.

### 10.3 Resolver false-match verification

`Sync::EspnTeamResolver` gained a one-word guard. **I could not reproduce the claim
that "Bayern Munich" resolved to "Inter"** with either the current or the
reconstructed pre-fix logic — both return `:no_candidate`. The change is therefore
reported as *a defensive guard backed by direct tests*, not as a confirmed
regression fix. The tests that do pass (`Napoli` vs `Roma`, single-word provider
names, multi-word head-word shares) were verified against the current code.

### 10.4 API-Football season resolution (fixed)

`lib/tasks/api_football.rake` used `Season.find_by(name: label)`. Test first showed
the contamination directly: an `E1` request received the **E0** season row.

The task now requires an internal competition code (`CODE=E0`), keeping the
provider league id (39) separate, and resolves the season within that competition.
Missing code, unknown competition and missing season all abort.

**It does not reuse `EspnLeagueSeason`**: that resolver maps ESPN *slugs* through
`EspnLeagueCoverage`, and API-Football league ids are a different identifier space
(39 ≠ "E0"). Sharing it would have coupled two providers to one map.

### 10.5 Detector retirement

`Sync::ForeignFixtureBleed` is retired in code, not deleted:

- `call` now raises `Sync::ForeignFixtureBleed::Retired` for every argument
  combination — the destructive branch is gone, not just guarded.
- `candidates` remains for forensic inspection.
- No rake task, job, schedule entry or service references the class; verified by
  search. There was no operational path to disable.
- The class comment records that its classifier (completed + future kickoff) does
  **not** match the 139 confirmed rows, and points to §8.7 for the real repair.

### 10.6 Mobile: collapsible seasons

New `src/domain/fixtureSections.ts` (pure, 14 tests) and
`src/components/CollapsibleSection.tsx` (6 tests). The Fixtures screen now renders
one section per season, newest first, current season open and older ones collapsed.

| Requirement | Implementation |
|---|---|
| Group by competition | Existing competition chips |
| Collapsible seasons | `CollapsibleSection` per season |
| Current season open | `defaultExpandedSeasonIds` |
| Older seasons collapsed | Same rule |
| Current season identified | "Current" badge + accessibility label |
| Expansion is free | Component holds no data access; expansion is local state only |
| Selection preserved | `seasonId` state retained; expanding does not change selection |
| Empty states distinguished | `upcomingEmptyReason` → no-fixtures / not-synced / unsupported-provider |

**Honest limitation:** `providerUnsupported` is currently hardcoded `false` in the
screen. The API does not expose which competitions lack a fixture provider, so the
"unsupported provider" state exists, is tested, and is reachable — but is not yet
wired to live data. Claiming otherwise would be a fabricated empty state.

### 10.7 Verification (actual)

```
backend rspec                          977 examples, 0 failures, 1 pending   exit 0
mnt resolver spec                      14 examples, 0 failures               exit 0
api_football_season_resolution_spec     6 examples, 0 failures               exit 0
foreign_fixture_bleed_spec              8 examples, 0 failures               exit 0
mobile tsc --noEmit                    0 errors                             exit 0
mobile jest                            148 passed, 13 suites                 exit 0
expo export --platform android          3.7 MB bundle, no warnings           exit 0
```

`espn_client_spec` was calling the old `from:`/`to:` keywords after the client
was changed to `from_date:`/`to_date:`; the spec was corrected, not the client.

### 10.8 Data integrity

| Metric | Before | After |
|---|---|---|
| matches | 39,976 | **39,976** |
| predictions | 62 | **62** |
| fingerprint | `09e9adb086a200d7319006e1cf48db77` | **identical** |

### 10.9 Blockers

1. **Nine competitions cannot receive fixtures** until their clubs are mapped
   (75 unresolved). Needs human review of a proposed mapping table.
2. **139 Championship fixtures remain under E0** (§8.2) — needs an approved
   reassignment migration, not a deletion.
3. **36 Scottish fixtures** have unresolved season assignments.

### 10.10 Proposed import scope (NOT EXECUTED — awaiting approval)

```
provider : ESPN
league   : eng.2   (E1, Championship)
season   : 2026/27
dates    : 2026-11-01 .. 2026-12-31
requests : ~61 (one per day)
writes   : scheduled fixtures only; reconciler rejects unmapped teams
risk     : zero completed-result overwrite (precedence rule §4)
rollback : new rows only; identifiers recorded per row
```

No import will run without explicit approval.

## 11. E1 (Championship) fixture-import preflight — 2026-11-02

**Read-only. No import was run, nothing was written, Sidekiq was not started.**
Database verified identical before and after: 39,976 matches, 62 predictions,
fingerprint `09e9adb086a200d7319006e1cf48db77`.

### 11.1 Headline: the proposed import would insert ZERO rows

```
window          : 2026-11-02 .. 2026-12-31   (60 days, 60 requests)
raw events      : 132, all status=scheduled
dates           : 2026-11-03 .. 2026-12-29
projected inserts : 0
would match existing: 132  (100%)
unresolved teams  : 0
duplicate pairs in feed: 0
```

Every one of the 132 Championship fixtures ESPN serves for that window is
**already in the database** — filed under E0's 2026/27 season. This is the §8
contamination, now measured exactly.

### 11.2 Mapping verification (correction to the handover)

| Claim | Actual |
|---|---|
| "E1 has 24 ESPN team mappings" | **35 mappings** on E1 clubs; 50 canonical E1 clubs (multi-season history) |
| 24 | That is ESPN's **current eng.2 roster size** — every one of the 24 is mapped (0 unmapped) |

All 24 live Championship clubs resolve. The 11 remaining mappings point at clubs
relegated from the Premier League; they are stale for this purpose, not wrong.
No mapping is missing or ambiguous **for the current Championship roster**.

### 11.3 Where the fixtures already are

| | |
|---|---|
| Contaminated rows matched | **132** |
| Location | `season_id = 6` (E0 2026/27), `competition_id = 4` (E0) |
| Status | all `scheduled` |
| ID range | 39676 … 39787 |
| Distinct Championship clubs involved | see inventory |
| football-data provenance | none (ESPN-only) |
| Predictions attached | none of the 132 |
| Already linked to an E1 (season 38) match | **0** |

E1 2026/27 (season_id 38) holds **0** matches. The fixtures exist; they are filed
in the wrong competition.

### 11.4 Import path (verified, unchanged)

`espn:discover[eng.2,2026/27]` → `Sync::EspnDiscoverySynchronizer` →
`Import::EspnClient` (`scoreboard_dates`) → `Import::EspnAdapter.normalize_fixture`
→ `Import::ApiFootballReconciler.apply_fixture(season:)`. No parallel write path.
Season resolution goes through `Sync::EspnLeagueSeason.for_league`, which returns
**E1 (season 38)**, not E0.

### 11.5 Safety assessment for the proposed import

| Item | Result |
|---|---|
| Expected new rows | **0** |
| Existing rows that would be skipped | 132 (matched by provider id) |
| Unresolved teams | 0 |
| Duplicate risk | none — provider ids unique, reconciler matches by identity |
| Provider requests | 60 (one per day) |
| Existing matches/predictions modified | **none** — the reconciler only skips a matched row |
| Rollback | n/a (nothing created) |

**Running this import achieves nothing.** It costs 60 requests and changes no data.

### 11.6 The real blocker

The 132 rows need to be **reassigned from E0 (season 6) to E1 (season 38)**, not
re-imported. Evidence for the reassignment is complete and per-row: each carries an
ESPN identifier (`40188xxxxxx`), is absent from football_data, is scheduled, has no
predictions, and ESPN serves it from `eng.2` — verified by the inventory, not by
inference from date or club names.

This remains **blocked pending approval**: it is an `UPDATE` of 132 existing rows
(competition_id + season_id), which is a data-repair migration, and §8.7 defined
the review standard for it.

### 11.7 Artifacts

- `backend/tmp/e1_preflight_mappings.rb` — mapping verification
- `backend/tmp/e1_preflight_inventory.rb` — inventory generator
- `/app/tmp/e1_fixture_inventory.json` — 132-row inventory (container-local)

### 11.8 Approval requested — corrected scope

```
OPTION A (recommended) — reassign, do not import
  rows     : 132, ids 39676..39787
  change   : competition_id 4 -> E1 id, season_id 6 -> 38
  untouched: teams, scores, kickoff, status, ESPN identifiers
  verify   : all 132 carry 40188xxxxxx ids and none carry football_data
  rollback : reversible UPDATE by id list

OPTION B — run the proposed import anyway
  result   : 0 new rows, 60 requests wasted. NOT recommended.
```

## 12. E1 reassignment repair — prepared, NOT executed (2026-11-02)

**No record was changed. The repair exists, is tested, and has never been run
against any database except the test database.**

Database verified identical before and after this work: 39,976 matches,
62 predictions, fingerprint `09e9adb086a200d7319006e1cf48db77`.

### 12.1 The handover figures were wrong — corrected here

§11 recorded "affected matches: IDs 39676–39787" and "132". Both are wrong.
Re-queried against the live database:

| Claim | Actual |
|---|---|
| IDs 39676..39787 | that range holds **112** matches in E0/season 6, not the affected set |
| 132 affected | **383** affected |
| "all affected are scheduled" | 371 scheduled + **12 completed** |
| "no football-data provenance" | correct — 0 of the 383 carry it |

A range query on ids cannot find these rows, so §11's number is not repair-grade.

### 12.2 The real partition of `eng.2` (40188) events

| Currently filed as | Status | Rows | Has football-data | Verdict |
|---|---|---|---|---|
| E0 / season 6 | scheduled | **371** | no | **repair target** |
| E0 / season 6 | completed | **12** | no | **repair target** |
| E1 / season 38 | completed | 144 | **yes** | correct, do not touch |
| E1 / season 38 | scheduled | 0 | — | — |

**383 rows are misassigned.** All carry a `40188xxxxxx` ESPN id, none carry
football_data provenance, none have predictions, and the 12 completed rows are
contested Championship results (Wrexham, Lincoln, QPR, Cardiff) sitting in the
Premier League.

### 12.3 A second defect found while building the repair

`football_data` identifiers are also used for TEAM mappings, and **469 of them
have a NULL `match_id`**. A `NOT IN (SELECT match_id ...)` against that column
yields NULLs, so Ruby's `id NOT IN (..., NULL)` evaluates to NULL for every row
and matches **nothing**. The exclusion silently disarmed itself and the repair
selected **zero rows**.

Fixed with `.where.not(match_id: nil)` and pinned by a regression test. This is
the same class of bug as the original season defect: a query that fails quietly
and reports success.

### 12.4 Repair design

`DataRepair::ReassignEspnChampionshipFixtures`

| Guard | Behaviour |
|---|---|
| Environment | refuses `Rails.env.production?` |
| Destination | season 38 must belong to E1; must differ from the source |
| Expected count | aborts if the affected count differs from the verified 383 |
| Source state | every selected row must still be in E0/season 6 |
| Row count | the UPDATE must affect exactly the selected ids, else roll back |
| Scope | provider evidence only: `40188` ESPN id, no football_data, club has E1 history |

Changes `competition_id` and `season_id` only. Teams, kickoff, status, scores and
ESPN identifiers are untouched.

**Rollback** uses the token returned by `call`: it restores exactly those ids, and
only where the row still holds the destination values. A row changed by another
route is skipped and reported, never overwritten.

### 12.5 Safety assessment

| Item | Result |
|---|---|
| Rows that would move | **383** (371 scheduled + 12 completed) |
| Rows modified | no result or score changes; competition/season only |
| Predictions affected | **0** |
| Collisions with existing E1 rows | **0** |
| Rows left in E0 | untouched; the 316 genuine `eng.1` rows stay |
| Reversible | yes, by id list from the token |

### 12.6 Verification

```
rspec spec/services/data_repair/reassign_espn_championship_fixtures_spec.rb
  13 examples, 0 failures            exit 0

rspec (full backend suite)
  990 examples, 0 failures, 1 pending   exit 0
```

The pending example is the documented skip for match 4280 (absent from the test DB).

### 12.7 Commands — SUPERSEDED by §12.10 (execution)

```ruby
# PREVIEW (read-only)
repair = DataRepair::ReassignEspnChampionshipFixtures.new
repair.affected_ids                     # => 383 ids (both statuses)
DataRepair::ReassignEspnChampionshipFixtures.new(include_completed: false).affected_ids  # => 371

# APPLY  — EXECUTED for the scheduled scope only, see §12.10
result = DataRepair::ReassignEspnChampionshipFixtures.new(expected_count: 371, include_completed: false).call

# ROLLBACK (NOT executed)
DataRepair::ReassignEspnChampionshipFixtures.new.rollback!(token)
```

⚠ **The 12 completed rows are contested results.** Moving a completed result
changes which competition its result counts toward. Approval for the 371
scheduled rows does not automatically cover those 12; they should be approved
separately. **They were NOT moved.**

### 12.10 EXECUTION — scheduled fixtures reassigned (2026-11-02)

**The repair ran. 371 scheduled rows were moved from E0/season 6 to E1/season 38.
The 12 completed rows were excluded and remain untouched.**

| | |
|---|---|
| Executed at | 2026-11-02 (UTC), via `rails runner` in the `web` container |
| Scope | `include_completed: false`, `expected_count: 371` |
| Rows updated | **371** |
| Destination | E1 (competition 7), season 38 |
| Environment | development, production refusal active |

**Database before → after**

| Metric | Before | After |
|---|---|---|
| total matches | 39,976 | **39,976** (unchanged — reassignment, not insert) |
| total predictions | 62 | **62** (unchanged) |
| E1 season 38 total | 144 | **515** (+371) |
| E0 season 6 total | 796 | **425** (-371) |
| E0 season 6 scheduled | 687 | **316** |
| E0 season 6 completed | 97 | **97** (unchanged) |

**Verification (independent SQL, not the service's own count)**

| Check | Result |
|---|---|
| Rows now in E1/season 38, scheduled | 371 ✓ |
| Attributes (teams, kickoff, status, scores) fingerprint | `05ba23d2…` — **identical to pre-execution snapshot** ✓ |
| ESPN identifiers intact | 371/371 carry `40188xxxxxx` ✓ |
| Moved rows that had football_data provenance | 0 ✓ |
| Moved rows that had predictions | 0 ✓ |
| `40188` rows left behind in E0/season 6 (scheduled) | **0** ✓ |
| Genuine `eng.1` rows still in E0/season 6 (scheduled) | 316 ✓ |
| The 12 contested completed rows | **still E0/season 6** (ids 39664–39675) ✓ |
| Other competitions modified | 0 ✓ |
| Sidekiq | still not running ✓ |

**API confirmation**

```
GET /api/v1/competitions  -> E0 match_count=425 completed=97
                             E1 match_count=515 completed=144
GET /api/v1/matches?season_id=38&status=scheduled  -> 371 rows
                            first 2026-11-03, last 2027-05-01
```

Nothing was fabricated: every moved row was an ESPN fixture already in the
database under the wrong competition.

**Tests**

```
rspec spec/services/data_repair/   13 examples, 0 failures
rspec (full suite)               990 examples, 0 failures, 1 pending
```

**Rollback token**

371 entries, each `match_id => [4, 6]` (original competition and season). Stored at
`/app/tmp/e1_repair_token.json` (container, plus `.bak`) and
`~/e1_repair_token_backup.json` (host, md5 `f168ca4e…`). The token contains no
database fingerprint — only match ids and the two original column values.

**Rollback has NOT been executed.**

```ruby
require "json"
token = JSON.parse(File.read("/app/tmp/e1_repair_token.json"))
DataRepair::ReassignEspnChampionshipFixtures.new.rollback!(token)
```

**Discrepancy recorded:** §11 reported "132 affected" and ids 39676–39787. Both
were wrong; the verified scheduled scope was 371 rows spanning 39664–39787 plus
later ids. §12.1–12.3 document the correction.

**Still outstanding (NOT approved, NOT executed)**

1. The **12 completed contested fixtures** (39664–39675) remain in E0. Moving them
   changes which competition those real results count toward.
2. E1 history (144 football-data-backed completed rows in season 38) is correct
   and was never in scope.

## 13. Full fixture coverage audit and synchronization preflight (2026-11-02)

**Read-only. No import, no synchronization, no record changed.** Baseline verified at
start: 39,976 matches, 62 predictions, Sidekiq stopped, rollback token present.

### 13.1 The answer to the question

**No — we do not have all upcoming fixtures. Nine of eleven competitions have
none.** But a synchronization run cannot fix that today: it would insert **zero**
rows, because those competitions have **no ESPN club mappings**.

### 13.2 Inventory (2026/27)

| Competition | Season | Total | Completed | Scheduled | Earliest | Latest |
|---|---|---:|---:|---:|---|---|
| E0 Premier League | 2026/27 (6) | 425 | 97 | 316 | 2026-08-21 | 2027-05-30 |
| E1 Championship | 2026/27 (38) | 515 | 144 | **371** | 2026-08-07 | 2027-05-01 |
| SC0 Scottish Premiership | 2026/27 | 84 | 84 | **0** | 2026-07-31 | 2026-10-25 |
| SP1 La Liga | 2026/27 | 96 | 96 | **0** | – | 2026-10-26 |
| D1 Bundesliga | 2026/27 | 81 | 81 | **0** | – | 2026-10-25 |
| I1 Serie A | 2026/27 | 94 | 94 | **0** | – | 2026-10-26 |
| F1 Ligue 1 | 2026/27 | 86 | 86 | **0** | – | 2026-10-27 |
| N1 Eredivisie | 2026/27 | 78 | 78 | **0** | – | 2026-10-25 |
| B1 Belgian Pro League | 2026/27 | 93 | 93 | **0** | – | 2026-10-25 |
| P1 Primeira Liga | 2026/27 | 82 | 82 | **0** | – | 2026-10-25 |
| T1 Super Lig | 2026/27 | 80 | 80 | **0** | – | 2026-10-26 |

Live / postponed / cancelled: **0 across all competitions**. The project has no
in-play source, which is expected and documented.

### 13.3 The cut-off is artificial, not a league gap

Every competition except E0/E1 stops between 2026-10-25 and 2026-10-27, each with
approx. 80–96 matches — about a quarter of a 34–38 match-day season. That is the
signature of the original backfill, which queried a fixed set of dates. It is a
**synchronization** gap, not a provider gap.

### 13.4 Provider coverage (measured, not assumed)

A contiguous 30-day sweep of November 2026 confirmed **every** mapped league
returns fixtures. Fixed sample dates had previously made P1 and T1 look dead; the
contiguous sweep disproved that. All eleven slugs are live.

**Provider coverage and database coverage are different things**, and here they
diverge completely.

### 13.5 The actual blocker: zero club mappings outside E0/E1

| Competition | Clubs | Approved ESPN mappings | Consequence |
|---|---:|---:|---|
| SC0, SP1, D1, I1, F1, N1, B1, P1, T1 | 12–20 each | **0** | every event rejected |

A one-week reconciliation probe (2026-11-14..11-22) proved this directly:

```
code events resolved unresolved existing stored
SP1    8        0          8         0      96
D1     9        0          9         0      81
... all nine identical: resolved=0, unresolved=all
```

The reconciler rejects rows with unmapped teams **by design** — a guessed identity
would corrupt the table. So a discovery run today would make ~2,000 HTTP requests
and write nothing.

### 13.6 Anomaly sweep (database integrity)

| Check | Result |
|---|---|
| Duplicate team-pair + kickoff | 0 |
| Duplicate provider identifiers | 0 |
| Scheduled with a score | 0 |
| Completed without scores | 0 |
| Match season/competition mismatched | 0 |
| `eng.1` rows filed under E1 | 0 |
| `eng.2` rows filed under E0 | **12** (the known contested completed rows) |

The database is consistent apart from the 12 knowingly-contested rows.

### 13.7 Synchronization preflight

| | |
|---|---|
| Command | `bundle exec rake 'espn:discover[<slug>,2026/27]'` |
| Provider | ESPN (scoreboard, one request per calendar day) |
| Dry run | **none exists** — `DRY_RUN` is supported only by `espn:map_teams` |
| Writes | yes, directly to the database |
| Needs Sidekiq | no |
| Requests for a full season | ~365 per league |
| Expected inserts today | **0** for the nine unmapped leagues |

The audit did **not** execute `espn:discover` even in a narrow window, because it
has no dry-run and would write.

### 13.8 What would actually close the gap

The blockers are in this order:

1. **Team mappings** for the nine competitions (the 75 unresolved clubs from §10.2).
2. **Then** a discovery run per league.

Running discovery first is wasted work — measured, not assumed.

### 13.9 Recommendation

**Fetch required, but provider mapping must come first.** Current coverage is
**partial**: complete for E0/E1 for the remainder of the season (subject to daily
refresh), and **absent** for the other nine because they were never mapped.

Suggested order, each awaiting approval:

1. Review and approve a club-mapping table for one league (e.g. SP1, 20 clubs).
2. Run `espn:discover` for that league over the season remainder.
3. Verify, then repeat for the next.

I have not changed a record, started a job, or imported anything.

## 14. Reusable multi-competition ESPN mapping and preview (2026-11-02)

**Read-only. No mapping was persisted, no fixture imported, no synchronization run.**
Database unchanged: 39,976 matches, 62 predictions, 44 ESPN team mappings, 0 pending.
Rollback token md5 unchanged.

### 14.1 What was built (reusable, not per-league)

| Component | Role |
|---|---|
| `Sync::EspnCompetitionPlan` | one competition's slug, season, clubs, evidence |
| `Import::EspnTeamIdentity` | provider team id -> canonical club (pure) |
| `Import::ReconciliationPreview` | what an import WOULD do; zero writes |
| `EspnAliasEvidence` | documented non-lexical aliases, keyed by competition |
| `espn:survey` rake task | the batch loop over any set of codes |

Reused unchanged: `Import::EspnAdapter`, `Import::ApiFootballReconciler`,
`Import::EspnTeamResolver`, `EspnLeagueCoverage`, `ExternalIdentifier`.

The old limitation was never in the adapter — it was that identity decisions had no
home. Adding a league is now a data entry, not a new service.

### 14.2 Two bugs found while building it

1. **Preview could not see proposed mappings.** It resolved teams only from
   `ExternalIdentifier`, so a dry run of a proposal reported `resolved=0` — which
   looked exactly like "the proposal is worthless". Fixed with an in-memory
   `team_index:` and pinned by a regression test.
2. **Evidence keyed by display name missed accented forms.** `Atlético Madrid`
   never found `"Atletico Madrid"`. Lookup now normalises the key first.

### 14.3 Survey results (2026-11-01 .. 2026-12-31, live ESPN)

| Competition | Clubs | Verified | Unmapped | Resolved events | Would create |
|---|---:|---:|---:|---:|---:|
| SC0 | 12 | 11 | 1 | 48 | 48 |
| **SP1** | 20 | **20** | **0** | 66 | 66 |
| D1 | 18 | 8 | 10 | 8 | 8 |
| I1 | 20 | 18 | 2 | 55 | 55 |
| F1 | 18 | 13 | 5 | 25 | 25 |
| N1 | 18 | 13 | 5 | 29 | 29 |
| B1 | 18 | **5** | **13** | 5 | 5 |
| P1 | 18 | 13 | 5 | 28 | 28 |
| T1 | 18 | 12 | 6 | 27 | 27 |

**SP1 (La Liga) is the pilot and the only competition fully mapped**: 20/20 clubs, 66
events resolved, 0 unresolved. Nine of its clubs needed documented alias evidence
(`Ath Bilbao` = `Athletic Club`, `La Coruna` = `Deportivo`, ...), each verified by
matching opponents and scores on identical dates.

**47 clubs remain unresolved across the other eight.** They are dominated by leading
club words (`1. FC Union Berlin`, `AS Roma`, `AC Milan`, `KAA Gent`), accents and
legal-name forms. They are reported, never guessed — a fixture is proposed only when
both clubs resolve, which is why "would create" falls with the unmapped count.

### 14.4 Zero-write guarantee

Specs stub `Match.create!`, `Match#update!` and
`ExternalIdentifier.find_or_create_by!` to raise, and assert counts are unchanged
across a full survey. The preview never calls `apply_fixture`.

### 14.5 Tests

```
espn_team_identity_spec        9 examples
reconciliation_preview_spec    8 examples
espn_competition_plan_spec     8 examples
espn_coverage_survey_spec      4 examples
full backend suite          1110 examples, 0 failures, 1 pending
```

### 14.6 Commands

```bash
# READ-ONLY
docker compose exec -T web bundle exec rake espn:survey
docker compose exec -T web env CODES=SP1 SEASON=2026/27 FROM=20261101 TO=20261231 \
  bundle exec rake espn:survey
```

### 14.7 Not done — awaiting approval

1. Persist the SP1 mappings (20 clubs). Nothing has been written.
2. Resolve the 47 remaining clubs by adding evidence entries.
3. Run `espn:discover` for any competition (no dry-run exists).

Documentation: `docs/espn_multi_competition_mapping.md`.

## 15. Complete 2026/27 fixture coverage — EXECUTED (2026-11-02)

**All 11 competitions now have upcoming fixtures.** 1,994 fixtures inserted across
nine competitions; completed results and predictions untouched.

### 15.1 What was done

| Step | Result |
|---|---|
| Resolve remaining identities | **47 resolved**, 0 unresolved |
| Evidence method | our result vs ESPN result: same date, opponent AND score (4/4 per club) |
| Mappings persisted | **160 new**, 0 rejected, 204 total (all approved) |
| Preview | 0 unresolved clubs, 0 conflicts |
| Discovery | 9 competitions x 3 windows (Nov-Dec, Jan-Mar, Apr-Jun) |
| Inserted | **1,994 scheduled fixtures** |

### 15.2 Coverage after execution

| Competition | Scheduled | First | Last |
|---|---:|---|---|
| E0 | 316 | 2026-11-02 | 2027-05-30 |
| E1 | 371 | 2026-11-03 | 2027-05-01 |
| SC0 | 126 | 2026-11-07 | 2027-04-10 |
| SP1 | 270 | 2026-11-06 | 2027-05-30 |
| D1 | 234 | 2026-11-06 | 2027-05-22 |
| I1 | 280 | 2026-11-06 | 2027-05-30 |
| F1 | 225 | 2026-11-06 | 2027-05-29 |
| N1 | 207 | 2026-11-06 | 2027-05-23 |
| B1 | 217 | 2026-11-04 | 2027-05-22 |
| P1 | 216 | 2026-11-06 | 2027-05-16 |
| T1 | 216 | 2026-11-06 | 2027-05-23 |

**2,679 scheduled fixtures total.**

### 15.3 Database integrity

| Metric | Before | After |
|---|---|---|
| matches | 39,976 | **41,970** (+1,994) |
| completed | 39,288 | **39,288** (unchanged) |
| predictions | 62 | **62** (unchanged) |
| duplicate provider ids | 0 | **0** |
| duplicate team+day | 0 | **0** |
| season/competition mismatch | 0 | **0** |
| contested 12 rows | E0 | **E0, untouched** |

Rollback token md5 `f168ca4e…` unchanged. Sidekiq not started.

### 15.4 New code

| File | Purpose |
|---|---|
| `app/services/sync/espn_mapping_persister.rb` | writes verified mappings; refuses ambiguous, never overwrites |
| `lib/tasks/espn_persist_mappings.rake` | batch persist (`DRY_RUN=1` supported) |
| `spec/services/sync/espn_mapping_persister_spec.rb` | 7 examples |

Alias evidence expanded from 9 (SP1 only) to **56 entries across 9 competitions**,
each carrying its verification basis.

### 15.5 Tests

```
sync + import + data_repair      0 failures
models + requests + jobs + lib + tasks   0 failures
remaining service specs          0 failures
total                        1008 examples, 0 failures, 1 pending
```

### 15.6 Honest limitations

1. **ESPN coverage was not exhaustively verified per date.** The season start and end
   dates per competition come from what ESPN returned, not from a full-season
   enumeration. A fixture ESPN adds later in the season will be picked up by the next
   run, but today's completeness is "everything ESPN returned for the three windows".
2. **Coverage is for the remaining season** (2026-11-03 onward). Earlier 2026/27
   fixtures came from football-data and were not re-touched.
3. The 12 contested completed rows remain in E0 (unchanged, as authorised).

## 16. ML audit — status and next actions (2026-11-02)

Full report: `docs/ml_audit_report.md`. Read-only; nothing retrained, promoted or changed.

### 16.1 Verdict

| Question | Answer |
|---|---|
| Can it produce predictions? | **YES** — all five markets verified end-to-end on match 4357 |
| Which markets work? | 1X2, O/U 2.5, BTTS, Double Chance (derived), Correct Score (grid, top-6 view) |
| Trustworthy for betting? | **NO** — no odds data exists anywhere in the project |
| Valid independent holdout? | **NO** — the protocol itself declares the test window exploratory |

### 16.2 Corrections to earlier reports

- `features_v2.py`, `goal_models.py`, `eval_pipeline.py`, Dixon-Coles and the
  multi-market path **all exist** in the current checkout.
- **Logistic regression is the published model**, selected by validation
  (`algorithm: multinomial_logistic_regression`). Prior text implying the goal model
  is the default was wrong for the current artifacts.
- The goal model is **not** competitive on validation: log loss 1.0625 vs 0.9828 for
  logistic regression.
- Dixon-Coles is implemented but **inert**: `rho = 0.04`, metrics identical to Poisson.

### 16.3 Key numbers (validation, n=5,006)

| Candidate | Accuracy | Log loss |
|---|---:|---:|
| frequency baseline | 0.4383 | 1.0740 |
| **logistic_regression (published)** | **0.5180** | **0.9828** |
| poisson_goals | 0.4429 | 1.0625 |

### 16.4 Priority findings

- **P0-1** No untouched holdout; every reported test metric is exploratory.
- **P0-2** No odds data, so no betting readiness can be assessed.
- **P1-1** No calibration applied (measured, never fitted).
- **P1-2** Dixon-Coles adds nothing at rho≈0.04.
- **P1-3** `model_comparison.json` and the artifact split disagree on ratios and seeds.

### 16.5 Next actions (awaiting authorisation)

1. Freeze artifacts; stop scoring the spent 2025-02-26+ window.
2. Build a holdout manifest so an evaluator can refuse spent dates.
3. Fit and persist a calibrator on validation data only.
4. Add odds ingestion before any betting claim.

## 17. Evaluation integrity and calibration infrastructure (2026-11-03)

Phases A and B of the validation workstream. **No model was retrained or promoted, no
calibrator was fitted or published, no artifact was modified, no automated job was
started.** Database unchanged: 41,970 matches, 67 predictions.

### 17.1 What was built

| Component | Purpose |
|---|---|
| `ml/app/eval_protocol.py` | versioned protocol, hashed boundaries, spent manifest, holdout gate |
| `ml/app/model_freeze.py` | immutable generation record with per-artifact SHA-256 |
| `ml/app/calibration.py` | metrics + identity/Platt/isotonic calibrators + disjoint study |
| `ml/evaluation/eval_protocol_v2.json` | authoritative protocol for the v2 generation |
| `ml/evaluation/spent_manifest.json` | what has been spent, and why nothing is clean |
| `ml/evaluation/model_freeze_v2.1.json` | frozen record of the published generation |
| `ml/scripts/freeze_current_generation.py` | regenerates the freeze, read-only |

### 17.2 The evaluation protocol (authoritative)

```
train_end      2023-12-03   (28,364 rows)  -> training
validation_end 2025-02-26   ( 5,006 rows)  -> model selection
after          2025-02-27   ( 5,889 rows)  -> EXPLORATORY, already scored
future         after freeze (     0 rows)  -> the only usable holdout
protocol digest recorded in model_freeze_v2.1.json
```

### 17.3 Reconciling the old discrepancy (P1-3 from the audit)

The audit flagged that `model_comparison.json` said 70/15/15 while the artifacts said
20/20. Resolution:

| Source | Numbers |
|---|---|
| `model_1x2.joblib.meta.json` split | 28,364 / 5,006 / 5,889 (59/10/12 of 39,259) |
| `model_comparison.json` | same three counts; the "70/15/15" is stale prose |
| database by kickoff date | 28,397 / 4,981 / 5,910 = 39,288 |

**The row counts agree; the ratio label was wrong, and the DB differs from the
artifact split by 29 rows because one uses date boundaries and the other timestamp
boundaries.** Both facts are recorded in the manifest rather than "fixed" by editing
a file. The new protocol is `v2.1` and does not inherit v1's 17-feature framing.

### 17.4 Why the evaluator now refuses to lie

`require_clean_holdout` rejects a row unless it is **both** after `validation_end`
**and** unspent. Either check alone is insufficient — the old harness satisfied the
date check and produced exploratory numbers as if they were final. The error names
every offending row.

`SpentManifest.load` raises when the manifest file is missing rather than returning
an empty manifest, because "I don't know what is spent" and "nothing is spent" must
never be the same answer.

### 17.5 Calibration infrastructure (not executed against production)

`CalibrationStudy` fits on a declared fit partition and scores on a disjoint
assessment partition, refusing overlap before any fitting occurs. Identity, Platt and
isotonic are implemented and compared side by side; none is assumed superior.

**Nothing was fitted on real data and nothing was published.** That requires approval.

### 17.6 Tests

```
python -m pytest tests/ -q         336 passed   (283 baseline + 53 new)
  test_eval_protocol.py    22
  test_model_freeze.py     11
  test_calibration.py      20
```

Run via an ephemeral container with the repo mounted read-only, because the running
`ml` service has code baked into its image from 2026-10-29 and a stale volume.

### 17.7 Designs produced (no implementation)

- `docs/prospective_evaluation_design.md` — prediction provenance, eligibility, the
  four evaluation categories, minimum samples.
- `docs/betting_intelligence_design.md` — odds storage, overround, margin removal
  (including why Double Chance must not be margin-adjusted as an exclusive market),
  EV, CLV, backtest limits, paper trading.

### 17.8 Still blocked

1. **No usable holdout.** Every completed match is spent. The holdout can only fill
   from matches completing after the freeze.
2. **Calibration not fitted.** Infrastructure only.
3. **No odds data.** Betting readiness remains unassessable.

### 17.9 Approvals required next

1. Fit calibration on the 2025-02-27+ partition and persist metadata (no production change).
2. Add `issued_at` / `model_freeze_digest` columns to begin prospective capture.
3. Select and verify an odds provider.

## 18. Phase C1 — prospective prediction capture (2026-11-03)

Infrastructure for immutable, timestamped predictions and auditable evaluation against
results. **No model retrained, no calibrator fitted, no artifact changed, no job started,
no commit.** Development database unchanged: 41,970 matches, 67 predictions.

### 18.1 Why this was needed

Every completed match is spent (handout §17). The only clean evidence left is a
prediction issued before kickoff and scored after the result. Nothing in the schema
recorded enough to make that distinction: `generated_at` existed but nothing checked
it, and a prediction's `outcomes` could be overwritten after the fact.

### 18.2 Schema changes (applied to TEST only)

| Change | Purpose |
|---|---|
| `predictions.issued_kickoff_at` | the kickoff the fixture had WHEN issued — makes rescheduling detectable |
| `predictions.model_freeze_digest` | ties a prediction to a frozen artifact generation |
| `prospective_evaluation_records` (new) | the auditable prediction → result link |

Both prediction columns are **nullable**: every existing row predates them and stays
NULL. A NULL means "provenance unknown", which eligibility treats as **not eligible**
rather than inferring.

**Migrations applied to `sports_betting_ai_test` only.** The development database has
not been migrated — `newcols=0` verified after the run.

### 18.3 Immutability

`Prediction` now refuses to change `outcomes`, `market`, `match_id`, `generated_at`,
`model_version`, `model_freeze_digest` or `issued_kickoff_at` after creation.
`superseded_at` remains writable, because superseding is the designed way to replace a
prediction and must not be blocked.

### 18.4 Eligibility (`Predictions::ProspectiveEligibility`)

A prediction counts as prospective evidence only when ALL hold:

| Reason rejected | Meaning |
|---|---|
| `missing_issued_at` | no timestamp |
| `issued_at_or_after_kickoff` | at or after kickoff: hindsight |
| `kickoff_changed_since_issue` | fixture rescheduled after the prediction |
| `missing_model_version` / `missing_feature_version` / `missing_freeze_digest` | unattributable |
| `match_not_completed` | no result (includes postponed/cancelled) |
| `missing_result` | completed but no scores (defensive; the DB forbids it) |

### 18.5 Evaluation (`Predictions::ProspectiveEvaluation`)

Writes a separate `prospective_evaluation_records` row. The issued probabilities are
**never modified**. Duplicate scoring is prevented twice — a Ruby check for a clear
error and a unique index on `prediction_id` for correctness under concurrency.

Outcome derivation follows the market: 1X2 → H/D/A, BTTS → yes/no, O/U → over/under,
correct score → the scoreline. Derived Double Chance and correct score keep their
existing semantics; no independent Double Chance model was added.

### 18.6 Provenance now captured by the producer

`Predictions::MarketPredictor` records `feature_version` (previously discarded) and
`model_freeze_digest` from the ML response, plus the kickoff at issue time. When the
service reports no digest, the column stays NULL rather than being invented.

### 18.7 Tests

```
spec/services/predictions/                     78 examples
spec/models/prediction_provenance_spec.rb      14 examples
full backend suite                          1188 examples, 0 failures, 1 pending
```

The pending example is the documented match-4280 skip on the test database.

### 18.8 Deployment still required (NOT done)

1. Run the two migrations against **development** — requires approval.
2. Deploy the new Rails code. The ML service is unchanged and needs no rebuild.
3. No background job exists yet; scoring is manual (`ProspectiveEvaluation#call`).

### 18.9 Known limits

- **The ML service does not currently emit `model_freeze_digest`.** Until it does,
  every prediction stores NULL and will fail eligibility by design. This is the
  correct behaviour — it makes the gap visible instead of silently attributing
  predictions to "whatever was deployed".
- `ProspectiveEvaluationRecord` has no bulk runner yet; one prediction per call.

## 19. Phase C2 — ML model provenance contract (2026-11-03)

Closes the gap in §18.9: Rails stored `model_freeze_digest`, but FastAPI never
returned one. **No artifact changed, no container rebuilt, no migration applied, no
prediction written, no commit.**

### 19.1 The contract

`PredictResponse` gained three **additive, optional** fields. Every previously
returned field is unchanged.

| Field | Meaning |
|---|---|
| `model_freeze_digest` | SHA-256 of the artifact that produced these probabilities, **only when verified** |
| `artifact_sha256` | the computed digest regardless of verification, for diagnosis |
| `provenance_status` | `verified` / `checksum_mismatch` / `not_in_freeze` / `no_freeze_record` / `artifact_missing` / `unavailable` |

`model_freeze_digest` is the **artifact's** SHA-256, not the protocol digest: it must
identify the exact file that answered. The protocol digest identifies the evaluation
rules, which is a different claim and must not be conflated.

### 19.2 Why not a constant

The digest is recomputed from the artifact's bytes at request time and compared with
`ml/evaluation/model_freeze_v2.1.json`. If the artifact were replaced after the freeze,
a constant would confidently attribute probabilities to a model that did not produce
them. Instead the mismatch is reported and **no digest is offered**, so Rails stores
NULL and its eligibility check (§18.4) treats the prediction as unattributable.

Failing closed is the design, not an accident: an honest NULL beats a plausible lie.

### 19.3 Files changed

| File | Change |
|---|---|
| `ml/app/model_provenance.py` | new: digest computation, freeze loading, verification |
| `ml/app/main.py` | provenance fields on `PredictResponse`; `_provenance_for`, `_artifact_path_for`; wired into both response sites |
| `ml/tests/test_model_provenance.py` | 11 examples |
| `ml/tests/test_provenance_response.py` | 7 examples |
| `ml/tests/test_api.py` | response-key assertion updated for the additive fields |
| `backend/spec/services/predictions/market_predictor_spec.rb` | 3 examples proving pass-through |

`model_provenance` reuses `model_freeze.sha256_of`, so the two cannot disagree about
how a checksum is computed.

### 19.4 Two bugs found while building this

1. **Duplicate `feature_version` keyword.** `_provenance_for` returned
   `feature_version`, which collided with the explicit argument in `PredictResponse(...)`
   and raised `TypeError` on every request. The field was removed from the provenance
   payload; the endpoint remains the single source.
2. **Wrong artifact path for the goal model.** I assumed `poisson_{market}.joblib`;
   the real file is `model_goal_distribution.joblib`. The earlier mapping would have
   reported `artifact_missing` for correct score on every request.

### 19.5 Tests

```
python -m pytest ml/tests/ -q     354 passed   (336 baseline + 18 new)
rspec market_predictor_spec        31 examples, 0 failures
```

### 19.6 Integrity

| Check | Result |
|---|---|
| All 5 artifacts vs freeze checksums | **all MATCH** |
| Artifacts modified | none |
| Development database | untouched (41,970 matches, 67 predictions) |
| Migrations applied | none |
| ML container rebuilt/deployed | **no** |
| Sidekiq | not running |

### 19.7 Deployment required (NOT done)

1. Copy `ml/evaluation/model_freeze_v2.1.json` to `/app/artifacts/freeze.json`.
   **It is not in the runtime volume today**, so the running service would report
   `no_freeze_record` and return no digest.
2. Rebuild and redeploy the ML image — the running container has code baked in from
   2026-10-29 and does not contain `model_provenance.py`.
3. Rails needs no change: it already passes the digest through unchanged.

### 19.8 Residual risk

- `MODEL_ARTIFACTS_DIR` / `MODEL_FREEZE_PATH` are environment-overridable. If the
  freeze path points at the wrong volume, provenance degrades to `no_freeze_record`
  rather than erroring — visible, but it will silently stop producing digests until
  someone notices.
- The runtime volume and the repo `ml/artifacts/` are separate copies. They match now,
  but nothing enforces that; the checksum check is what detects drift, and it needs
  the freeze record to be present.

## Appendix — earlier reports (kept verbatim)

# 2026/27 Premier League Fixture Backfill — End-of-Day Report

**Date:** 2026-10-30
**Status:** Operations paused, database verified, ready for continuation

## 1. Investigation Summary

The investigation established that only 7 scheduled fixtures appeared in the database for the 2026/27 Premier League season, all dated 21 November 2026. The root cause was traced to the ESPN backfill mechanism (`lib/tasks/espn.rake` and `EspnSynchronizer`), which had only queried two dates (2026-10-25 and 2026-11-21) via the `espn:sync` rake task, despite ESPN providing fixtures across the full current-season calendar from August 2026 through May 2027.

## 2. Commands Executed Today

### ESPN fixture discovery
```bash
for date in 20261122 20261123 ... 20270530; do
  curl -s "https://site.api.espn.com/apis/site/v2/sports/soccer/eng.1/scoreboard?dates=$date"
done
```

This queried 71 dates across November 2026 through May 2027, confirming ESPN has fixtures on 53 of those dates with a total of 361+ events.

### ESPN backfill execution
```bash
for date in 20261122 20261123 ... 20270530; do
  docker compose exec web bundle exec rake espn:ingest[eng.1,"2026/27",$date]
done
```

Each date was processed individually via `Sync::EspnSynchronizer#call` with `Import::EspnClient` and `Import::EspnAdapter`, running through `Import::ApiFootballReconciler` for duplicate prevention and mapping.

### Database verification
```bash
docker compose exec web bundle exec rails runner 'season = Season.find_by(name: "2026/27"); ...'
```

### Rails API verification
```bash
docker compose exec web curl -s "http://localhost:3000/api/v1/matches?season_id=6&status=scheduled"
```

## 3. Root Cause

The ESPN backfill had only queried two dates (2026-10-25 and 2026-11-21). The `EspnSynchronizer` loops over events from a single date scoreboard request and runs each through the reconciler — it does not automatically discover or iterate the full season calendar. The `rake espn:sync` task was not configured with a date range, so it only processed the two explicitly provided dates.

The synchronizer itself is correct: it reuses the reconciler for idempotent writes, maps provider team IDs via `ExternalIdentifier`, and preserves completed results. The gap was purely in the discovery/iteration layer.

## 4. Results After Backfill

- **Total 2026/27 matches:** 360 (was 87)
- **Completed:** 80 (pre-existing historical matches)
- **Scheduled:** 280 (was 7, now covers Aug 2026 – May 2027)
- **Earliest fixture:** 2026-08-21T20:00:00Z
- **Latest fixture:** 2027-05-30T15:00:00Z
- **Next scheduled fixture:** id=4357, Man City vs Fulham, 2026-11-21T12:30:00Z

All 20 Premier League teams have ESPN external identifier mappings. Match 4280 (Arsenal v Chelsea, 2025/26 season, status=scheduled) is untouched.

## 5. Verification — API Consistency

- Rails `api/v1/matches?season_id=6&status=scheduled` returns 280 matches matching DB
- Mobile API contract (`api-contracts.md`) is satisfied
- No fixtures missing from DB that the API returns, and vice versa

## 6. What Remains Unresolved

- The underlying mechanism for automated full-season ESPN discovery needs design:
  - Should `espn:sync` iterate all dates in a loop?
  - Should there be a "discover" phase that first queries all dates?
  - How to handle rate-limiting and failed requests across 71 dates?
- The `espn:sync` rake task should be updated to accept a date range or iterate the full calendar
- No mobile-side changes are needed — the app correctly queries `/api/v1/matches?season_id=6&status=scheduled`

## 7. Next Investigation and Execution Steps (Tomorrow)

1. **Design an automated ESPN full-season discovery** — either modify `espn:ingest` to loop over all dates, or add a new `espn:discover` task that queries each date and reports successes/skips/conflicts.
2. **Update `lib/tasks/espn.rake`** to accept a date range or automatically discover the season calendar.
3. **Verify mobile app** connects to the updated API with all 280 scheduled fixtures.
4. **Run the full RSpec suite** to confirm no regressions (known 138 pre-existing failures are unrelated).
5. **Update handout.md** with progress and any new findings.

## 8. Running Services (for Tomorrow)

- `docker compose up -d` — all services (web, postgres, redis, ml, sidekiq) are healthy
- Rails console available via `docker compose exec web bundle exec rails runner`
- ESPN backfill via `bundle exec rake espn:ingest[eng.1,"2026/27",<YYYYMMDD>]`
- No ESPN requests or imports currently in progress
- Redis has queued jobs from previous runs but no active processes

## Preservation Notes

- Match 4280 (Arsenal v Chelsea, 2025/26) remains untouched
- No `.env` modifications
- No database resets or volume modifications
- No Git commits or pushes
- All 360 2026/27 matches preserved with external identifiers and provenance intact
- API contracts unchanged
## 20. Full work session — 500 diagnosis, provenance deployment, pipeline verification (2026-11-04)

Resumed from §19. **No commit, no amend, no push, no branch change** (HEAD still
`0c42db6`, branch `main`). No volume was pruned, no database reset, no historical
match or prediction record was deleted or rewritten. No model was retrained,
promoted, or recalibrated. Sidekiq is still not running.

### A. The HTTP 500

There were **three separate defects**, not one. The first two returned HTTP 500 on
different endpoints; the third was a hole that let bad evidence be stored.

#### A.1 `PendingMigrationError` — every `/api/v1/*` path

| | |
|---|---|
| Endpoint | **all** API routes, including `POST /api/v1/predictions` |
| Root cause | Phase C2's two migrations were unapplied in development (§18.8), so Rails' `CheckPending` middleware raised `ActiveRecord::PendingMigrationError` before the router ran |
| Why it happened | The migrations were applied to the **test** database only. `config.active_record.migration_error = :page_load` is the development default, and it is *correct*: the code expects columns the schema did not have |
| Before C2? | No — this instance is purely a C2 deployment gap |
| Markets affected | All five, plus every other endpoint |
| Fix | Applied both migrations to development (see B) |
| Regression test | `spec/middleware/check_pending_visibility_spec.rb` |
| Evidence | The dev log for 2026-11-03 contains **zero** `Completed 5xx` lines; every request in it was made over curl before C2 was merged into the running container. The failure was reproduced by `bin/rails runner` reporting `needs_migration? = true` with the three C2 columns absent. After migrating, all endpoints returned 200 and the suite's own probe (`ActiveRecord::Base.connection.migration_context.needs_migration?`) returns `false` |

**Not fixed by widening the health middleware.** `BypassPendingMigrationsForHealth`
still answers only `/api/v1/health` and `/api/v1/ready`. Swallowing the check on API
paths would have converted a loud 500 into a quiet wrong answer. The new spec fails
if anybody adds an API path to that bypass; a comment recording the incident was
added to the middleware.

#### A.2 `PG::CheckViolation` on `predictions_probabilities_sum_to_one` — 5 of 11 competitions

| | |
|---|---|
| Endpoint | `POST /api/v1/predictions`, **1X2 only** (every other market stores a neutral 0/0/1 triple) |
| Failing request | `POST /api/v1/predictions {"match_id": N, "markets": ["1x2", ...]}` for Cagliari v Como (I1), RB Leipzig v Mainz 05 (D1), EVV Echt v AZ Alkmaar (N1), OH Leuven v Antwerp (B1), Besiktas v Fenerbahce (T1) |
| Stack trace | `Prediction#save` → `INSERT INTO predictions` → `PG::CheckViolation: new row violates check constraint "predictions_probabilities_sum_to_one"`, DETAIL `(...)= (…, 0.40935, 0.27130, 0.31936) …` |
| Root cause | The three legacy columns are `numeric(6,5)`. The ML service rounds each probability **independently** to five decimals. The sum of three independently-rounded values is not always 1 — here **1.00001** — and the constraint demanded exact equality |
| Why it happened | The constraint was written as if the schema could represent a distribution exactly. It cannot, at five decimals |
| Existed before C2? | **Yes.** Identical by inspection: the constraint and the rounding are unchanged since the schema was created. It surfaces per-competition because it depends on the third decimal of the probabilities |
| Markets affected | 1X2 only (and therefore the Double Chance rows that copy the 1X2 triple) |
| Environment | The **test** database applied the *same* rounding (the Pg gem enables `extra_float_digits=3`, see below), so the defect was not partitioned by environment — it was unsampled |
| Fix | Migration `20261104100000_relax_prediction_sum_constraint_for_rounding.rb`: equality → tolerance `0.00001`, the largest conceivable rounding drift being 3 × 0.000005 = 0.000015. Non-negativity, at-most-one and the Double Chance agreement check remain exact |
| Regression test | `spec/models/prediction_probability_rounding_spec.rb` (7 examples) — written first, **failed with the exact production error**, then passed after the migration |

A test-only note worth keeping: a `psql` sum of the stored row shows `1.00001`,
while Ruby's `BigDecimal` sum of the same values shows `1.0`. That is not a
contradiction — it is the reason the bug survived sampling. Any future check of this
constraint must compare **stored digits**, not Ruby floats.

**Deliberately not "fixed" by renormalising.** Nudging `away` to `0.31935` would make
the digits add up and would silently change the model's output. The stored
distribution must be the one that was issued.

#### A.3 Predictions issued after kickoff (found during the pipeline sweep)

| | |
|---|---|
| Endpoint | `POST /api/v1/predictions` |
| Symptom | Not a 500 — two fixtures (39662 in E0, kicked off 2026-11-02; 39676 in E1, 2026-11-03) had results the provider had published but the database had never ingested. They still read `scheduled`, so the sweep issued predictions hours **after** kickoff |
| Root cause | `Predictions::MarketPredictor` refused a `completed` match but never compared `kickoff_at` with the clock. The stored status is an ingestion artefact, not a statement about time |
| Fix | The producer now refuses a fixture whose kickoff has passed, whatever its stored status. Ten affected rows remain stored and are **refused as evidence** by the existing eligibility gate — not deleted, not counted |
| Regression test | `spec/services/predictions/market_predictor_kickoff_spec.rb` (3 examples), plus the suite-wide correction described in D.3 |

#### A.4 Two model/spec defects found while making the suites green

- `Prediction` required the legacy columns, so `Prediction.create!(outcomes:)` alone
  raised a NOT NULL violation. C1's own spec built rows that way and **could never
  have passed**. Fixed with an `after_initialize` hook deriving the triple from
  `outcomes` for 1X2 rows only; an explicit value from the producer still wins.
- `spec/models/prediction_provenance_spec.rb` and
  `spec/services/predictions/prospective_evaluation_spec.rb` asserted behaviour the
  code never had (a defaulted `generated_at`, a writable `most_likely_outcome`, a
  completed-match-first construction, and a comment contradicting its own
  assertion). The specs were corrected to the real — and correct — contracts, not
  the code to the specs.

### B. Deployment

| Item | Result |
|---|---|
| Migrations applied to **development** | `20261103120000` (provenance columns), `20261103121000` (evaluation records), `20261104100000` (sum tolerance) |
| Migrations applied to **test** | the same three |
| Migration shape | additive only: three nullable columns, one index pair, one new table, one constraint relaxed. `down` exists for all three |
| Historical data touched by migration | none. The two provenance columns stay NULL on all 134 pre-existing rows |
| Fingerprints before → after migrations | matches `2f1a…` identical, predictions identical, 41,970 → 41,970 rows |
| ML image rebuilt | **yes** — `sports-betting-ai-ml:latest`, image id `536ac3e8f7d4`, built 2026-11-04 |
| ML boot defect fixed during rebuild | `model_provenance.py` imported `from app.model_freeze`, which resolves under pytest (which puts `ml/` on `sys.path`) but **crashed the container at boot** with `ModuleNotFoundError` under `PYTHONPATH=/app`. Changed to `from ml.app.model_freeze`, matching `main.py`. The container is now `Up (healthy)` where the first attempt was `Restarting` |
| Freeze record deployed | `ml/evaluation/model_freeze_v2.1.json` → `ml/artifacts/freeze.json` (copied with `cp -n`; no artifact was overwritten), mounted into the container at `/app/artifacts/freeze.json` |
| Artifact checksums vs freeze | **all 5 MATCH** — `model.joblib 1f21cab4…`, `model_1x2.joblib 99bd1a05…`, `model_btts.joblib d1b0d0d3…`, `model_goal_distribution.joblib 41da41cb…`, `model_over_under_2.5.joblib 17f7fe91…` |
| Freeze record sha256 | `377df079c8a91330…` (repo copy and container copy identical) |
| Rails | no code change needed for provenance; the C1/C2 Rails code was already in the working tree and is now actually running against a migrated schema |
| Services restarted | `ml` (rebuilt), `web` (restarted earlier, code already present) |
| Sidekiq | **still stopped** |

#### B.1 Runtime provenance verification (live, all five markets, match 40510)

```
1x2              status=verified  digest=model_freeze_digest  artifact=41da41cb…  fv=goal-dc-v2
double_chance    status=verified  digest=<same>              artifact=41da41cb…  fv=goal-dc-v2
over_under_2.5   status=verified  digest=<same>              artifact=41da41cb…  fv=goal-dc-v2
btts             status=verified  digest=<same>              artifact=41da41cb…  fv=goal-dc-v2
correct_score    status=verified  digest=<same>              artifact=41da41cb…  fv=goal-dc-v2
```

The digest offered is the **protocol digest** (`protocol_digest`), and
`artifact_sha256` is the answering file's hash — they are different claims and are
reported separately, as §19.1 required.

#### B.2 Fail-closed verification (the cases the brief demanded)

`ml/scripts/provenance_negative_probe.py` runs each case against a throwaway copy of
the artifact directory in a separate uvicorn; the real artifacts are never touched.

| Scenario | HTTP | `provenance_status` | Digest offered |
|---|---|---|---|
| control, untouched copy | 200 | `verified` | yes |
| freeze record missing | 200 | `no_freeze_record` | **no** |
| answering artifact missing | 503 | `artifact_missing` | **no** |
| answering artifact tampered (one byte appended) | 200 | `checksum_mismatch` | **no** |
| classifier artifact tampered, `source=classifier` | 200 | `checksum_mismatch` | **no** |
| freeze record malformed | 500 | — (visible deployment error) | **no** |

All six behave as designed. The first attempt at this probe **failed**, and the
failure was real: it deleted `model_1x2.joblib`, but the service's default source is
`goal_model`, so the provenance was still `verified` — the deleted file was never the
one answering. The probe was corrected to remove the artifact that actually answers.

#### B.3 Rollback

```bash
# code: nothing was committed, so rollback is not a git operation
# database (all three migrations are reversible):
docker compose exec -T web bin/rails db:rollback STEP=3   # dev
#   NOTE: the sum-constraint rollback TIGHTENS the constraint back to = 1 and will
#   fail if any stored row needs the tolerance. That is intentional: a rollback must
#   not create data the forward migration declared invalid.
# ml image:
docker compose build ml          # rebuilds from the working tree
# the previous image id was recorded above; the runtime volume and artifacts were
# never modified, and freeze.json is an additive file (delete it to return to
# no_freeze_record, which fails closed).
```

### C. Prediction system — end to end

`scripts/verify_prediction_pipeline.py` drives the real path
**Rails API → FastAPI → Rails → JSON** for one upcoming fixture in each of the 11
competitions, all five markets, and asserts market semantics.

| Check | Result |
|---|---|
| Competitions exercised | **11 / 11** — E0, E1, SC0, SP1, D1, I1, F1, N1, B1, P1, T1 |
| Markets per competition | 5 / 5, HTTP 200/201 |
| 1X2 sums to 1 | pass (11/11) |
| Over/Under 2.5 sums to 1 | pass (11/11) |
| BTTS sums to 1 | pass (11/11) |
| Double Chance sums to 2, and 1X = H+D, X2 = D+A, 12 = H+A **exactly** | pass (11/11) |
| Correct Score = 6 lines, each in [0,1], total ≤ 1 | pass (11/11) |
| Provenance fields present and `verified` | pass |
| Mobile → FastAPI direct calls | **none** — zero references to port 8000 in `mobile/src` or `mobile/app`; the client targets `EXPO_PUBLIC_API_BASE_URL` (Rails) only |

Error handling, live:

| Request | Result |
|---|---|
| completed match | 422, `a completed match already has a result; predicting it would be hindsight` |
| fixture whose kickoff has passed but status still `scheduled` | 422, `this fixture has already kicked off; a prediction now would be hindsight` (verified by temporarily shifting a fixture's kickoff inside a transaction and restoring it — the stored row was left unchanged) |
| unknown match | 404, honest message |
| unsupported market | 400, names the market |
| missing `markets` | 400, validation message |
| ML container stopped | 503 with `the ML service is unreachable`; **no prediction row written, no fallback probability invented** |
| ML restarted, cold start | first 1X2 request loads the goal model then answers; provenance `verified`; subsequent requests are warm |

**Known limitations (unchanged, and not papered over):** the models are at baseline
quality (~51% 1X2 accuracy against a ~46% majority baseline), Correct Score hits the
exact scoreline ~9% of the time, and there is no odds data anywhere in the project.

### D. Testing — commands and actual results

| Suite | Command | Result |
|---|---|---|
| Backend (full) | `docker compose exec -T web bundle exec rspec` | **1100 examples, 0 failures, 1 pending** |
| — of which new | 4 new spec files | 29 examples: 7 rounding + 11 pending-visibility + 8 sweep + 3 kickoff |
| ML (full) | `docker compose exec -T ml sh -c 'cd /app/ml && python -m pytest tests/ -q'` | **354 passed, 1 warning** |
| Mobile types | `cd mobile && npx tsc --noEmit` | **exit 0, 0 errors** |
| Mobile tests | `npx jest` | **148 passed, 13 suites** |
| Mobile bundle | `npx expo export --platform android --output-dir /tmp/…` | **exit 0** (output written to `/tmp` and removed) |
| Pipeline | `python3 scripts/verify_prediction_pipeline.py` | **ALL MARKETS OK** (11 competitions × 5 markets) |
| Reliability | `python3 scripts/audit_prediction_reliability.py` | **AUDIT PASSED** |
| Provenance negatives | `docker compose exec -T ml python /app/ml/scripts/provenance_negative_probe.py` | **ALL CASES PASS** (6 scenarios) |
| Container health | `docker compose ps` | ml, postgres, redis, web all `Up (healthy)`; sidekiq stopped |

The 1 pending example is the documented match-4280 skip (absent from the test DB).

#### D.1 Note on the mobile numbers

Jest now reports **148** passing tests in **13** suites, where §7 recorded 128 in 11.
Nothing was added by this session — the two extra suites were already in the tree.
This report states what was executed, not what a previous report said.

#### D.2 ML tests run **inside the real image**

§17 ran pytest in an ephemeral container because the image was stale. This session
runs them in the **rebuilt, running** image, so the import path that actually boots
the service is the one under test. That is precisely how the `ml.app` boot defect
would have been caught earlier.

#### D.3 A test-quality defect fixed

`market_predictor_spec.rb`, `prediction_requests_spec.rb` and
`double_chance_bootstrap_spec.rb` all used `kickoff_at: Time.utc(2026, 8, 20, 15)` and
`Time.utc(2026, 11, 7, 15)`. Once the producer refuses past kickoffs, those dates turn
into **silently stale tests** — they would pass or fail based on today's date. All
three now use `2.days.from_now` / `3.days.from_now`, and the one assertion on the
literal kickoff now compares against the fixture itself.

### E. Data integrity

| Metric | Before this session | After |
|---|---|---|
| matches | 41,970 | **41,970** (no insert, no delete) |
| completed | 39,288 | **39,298** (+10: results ingested, see below) |
| scheduled | 2,682 | **2,672** (−10) |
| predictions | 134 | **189** (+55 issued by the pipeline sweeps) |
| prospective evaluation records | 0 | **0** |
| historic predictions rewritten | — | **0** (fingerprint over `id\|market\|outcomes\|superseded_at` unchanged for the rows that already existed) |
| match fingerprint over `id\|scores\|status\|competition\|season` | — | **unchanged** — no fixture was reassigned, deleted or re-scored |
| 12 contested E1 rows in E0 | still in E0 | **still in E0** (untouched) |
| Rollback token | md5 `f168ca4e…` | unchanged |
| Sidekiq | not running | **not running** |
| Commits / pushes | — | **none** |

**The 10 completions** came from `tmp/ingest_recent_results.rb`, which is the only
write to match rows this session. Preview was run first and each score was
cross-checked against the ESPN scoreboard for that date, with team identity confirmed
through approved `ExternalIdentifier` mappings. It only completes rows that were still
`scheduled`; it creates nothing, moves nothing between competitions, and leaves any
row that already had a result untouched. Both runs are recorded in `sync_runs`
(kind `results`).

**One ledger row was closed manually:** run 113 was opened by a preview script that
then raised `undefined column` (a bug in the script, before any write). It was marked
`failed` with that explanation rather than left `running`, so the stale-run reaper
does not confuse it with a crashed import.

#### E.1 Prediction-number discrepancy, recorded rather than glossed

§18/§19 report 67 predictions; the database held **134** at the start of this session.
The extra 67 are from §12–§15-era runs whose console commands were not written into
the handover. Their content is intact and their provenance is correctly NULL. I did
not overwrite them and did not backfill them.

### F. Readiness — three different questions

| Question | Answer | Basis |
|---|---|---|
| **Is the system technically operational?** | **YES** | 11 competitions × 5 markets end-to-end; provenance verified; feature versions consistent; probabilities valid; 1100 + 354 + 148 tests green; errors diagnosable; prospective capture works |
| **Is it statistically validated?** | **NO** | calibration not fitted; prospective sample is **zero**; no untouched holdout exists yet |
| **Is it ready for real money?** | **NO** | no odds data of any kind; no EV, no CLV, no calibration, no sample |

### G. Outstanding work

1. **Prospective evidence is insufficient — this is the dominant blocker.** Zero
   predictions currently qualify. The pipeline works; only time and a daily ingest
   produce evidence.
   **INSUFFICIENT EVIDENCE — NO BETTING RECOMMENDATION.**
2. **Result ingestion is manual.** `tmp/ingest_recent_results.rb` is a script, not a
   task or a job. Scheduling it would start the kind of automated write §8.6 warns
   about; that needs an explicit decision.
3. **Calibration not fitted.** Infrastructure exists and is tested; fitting is
   unauthorised.
4. **No odds data.** Plan in `docs/betting_intelligence_design.md` §11.
   football-data.co.uk is recommended first (free, no account, same source as our
   results); a live provider is not needed until the retrospective diagnostic says
   something.
5. **No untouched holdout.** It fills only with matches completing after the freeze.
6. **The two fixtures whose results were late** show the ingestion cadence is behind
   the fixture list. A daily result pass is the operational fix.
7. **Mobile not run on a device.** No Android SDK/AVD on this host; `tsc`, Jest and
   the Android bundle are the strongest evidence available here.
8. **Live matches and league table** remain unbuilt (unchanged since §6.8).

### H. New and changed files this session

| File | Purpose |
|---|---|
| `backend/db/migrate/20261104100000_relax_prediction_sum_constraint_for_rounding.rb` | the 500 fix |
| `backend/spec/models/prediction_probability_rounding_spec.rb` | regression test (written first, failed, then passed) |
| `backend/spec/middleware/check_pending_visibility_spec.rb` | pins which paths bypass the pending-migration check |
| `backend/spec/services/predictions/market_predictor_kickoff_spec.rb` | post-kickoff refusal |
| `backend/spec/services/predictions/prospective_sweep_spec.rb` | sweep behaviour |
| `backend/app/services/predictions/prospective_sweep.rb` | manual scoring sweep (dry by default) |
| `backend/lib/tasks/predictions.rake` | `rake predictions:sweep [APPLY=1]` |
| `backend/app/models/prediction.rb` | derive the legacy triple from `outcomes` for 1X2 |
| `backend/app/services/predictions/market_predictor.rb` | refuse a fixture whose kickoff has passed |
| `backend/app/middleware/bypass_pending_migrations_for_health.rb` | comment recording the incident and why it is not widened |
| `backend/tmp/ml_probe_body.rb`, `backend/tmp/ingest_recent_results.rb`, `backend/tmp/sync_preview_last_days.rb` | operator scripts used for verification |
| `ml/app/model_provenance.py` | import path fixed to `ml.app.*` (container boot) |
| `ml/scripts/provenance_negative_probe.py` | six-scenario fail-closed probe |
| `scripts/verify_prediction_pipeline.py` | 11 × 5 end-to-end verification |
| `scripts/audit_prediction_reliability.py` | read-only reliability audit |
| `docs/prospective_evaluation_design.md` | §10: implemented status and operating procedure |
| `docs/betting_intelligence_design.md` | §11: paper-trading gap analysis and plan |
| specs corrected (not weakened) | `prediction_provenance_spec`, `prospective_evaluation_spec`, `market_predictor_spec`, `prediction_requests_spec`, `double_chance_bootstrap_spec` |
## 21. Phase D1 — prospective evidence collection infrastructure (2026-11-04)

Resumed from §20. **No commit, no push, no branch change** (HEAD still `0c42db6`).
No model retrained, calibrated, promoted or replaced. No odds ingested. No bet
placed. Sidekiq and cron still stopped. No scheduled job was added.

### 21.1 What already existed (and was therefore not rebuilt)

| Component | State found | Reused by D1 |
| --- | --- | --- |
| `Predictions::ProspectiveEligibility` | complete, 8 rejection reasons | yes, unchanged |
| `Predictions::ProspectiveEvaluation` | complete, unique-index protected | yes, unchanged |
| `Predictions::ProspectiveSweep` + `rake predictions:sweep` | added in §20 | yes, unchanged |
| `Prediction` immutability + provenance columns | live | yes, unchanged |
| `Sync::SyncRun` ledger | complete, kinds `fixtures`/`results` | yes, `results` kind |
| `Sync::EspnSynchronizer` | fixture import, no preview | **not** extended — see 21.2 |
| `Sync::EspnDiscoverySynchronizer` | fixture discovery | untouched |
| `Import::ApiFootballReconciler` | identity, duplicates, reschedule, conflict precedence | yes, unchanged |
| `Import::EspnClient` / `Import::EspnAdapter` | provider access + status precedence | yes, unchanged |
| `Sync::ResultSynchronizer` (football-data CSV) | daily CSV result import | untouched |
| `SyncFixturesJob` / `SyncResultsJob` / `SyncEspnDiscoveryJob` | exist, **not running** | untouched |
| `SidekiqCronSchedule` | 4 entries defined, **not registered** | untouched |

### 21.2 Result synchronization — what was built

`Sync::EspnResultSynchronizer` (`app/services/sync/espn_result_synchronizer.rb`).

**Why a new class rather than a `dry_run:` flag on `EspnSynchronizer`.** The fixture
synchronizer reports created/updated/skipped for a day of events. A result run has
to answer different questions — which event is a final result, which conflicts with
a stored result, which fixture moved — and an operator must read those answers
*before* anything is written. Bolting a flag onto the fixture path would have welded
two different reports onto one counters row.

**What it reuses.** `Import::EspnClient`, `Import::EspnAdapter`,
`Import::ApiFootballReconciler` (through its own private helpers, so there is one
implementation of "is this a conflict"), and `Sync::SyncRun`.

| Behaviour | Implementation |
| --- | --- |
| Preview writes nothing | `preview` never calls `apply_fixture`; ledger records `mode=preview`, `updated=0` |
| Never creates a fixture | an event with no stored match is `skipped`, not created |
| Never overwrites a stored result | the reconciler returns `:conflict`; the run lists it and leaves the row |
| Postponed / cancelled / abandoned | status change only, **no score invented** |
| Rescheduled | kickoff change reported separately; not treated as a result |
| Season association | a match in another season is treated as unknown (the reconciler's lookup is not season-scoped) |
| Unmapped club | `rejected`, never guessed |
| Provider failure | ledger row `failed`, nothing written, no exception escapes |
| Audit | every run is a `sync_runs` row with per-match detail |

Operator entry point: `rake 'results:sync[FROM,TO]'` (preview) and `APPLY=1` to write.
`LEAGUES=eng.1,eng.2` limits the scope. **Not scheduled.**

### 21.3 Dry-run results (live ESPN, 2026-11-01 .. 2026-11-04, all 11 leagues)

```
E0   fetched=10  completed=0  unchanged=10  conflicts=0  rescheduled=0  postponed=0  rejected=0  ignored=0
E1   fetched=12  completed=0  unchanged=9   conflicts=0  rescheduled=0  postponed=0  rejected=0  ignored=3
SC0  fetched=0   … (no fixtures in the window)
SP1  fetched=0   …
D1   fetched=0   …
I1   fetched=0   …
F1   fetched=0   …
N1   fetched=0   …
B1   fetched=0   …
P1   fetched=0   …
T1   fetched=0   …
TOTAL fetched=22 completed=0 unchanged=19 conflicts=0 rescheduled=0 postponed=0 rejected=0 ignored=3
```

**Proposed changes: none.** Every event in the window is already stored with the
same result. The 3 ignored E1 events are non-final statuses. This is the expected
outcome: §20 already ingested the 10 results that were missing.

**Conflict detection verified against real data.** Match 39676's stored score was
temporarily changed to 5–5 inside a guarded block, the preview was run, and it
reported exactly one conflict with `stored_score [5,5]` / `provider_score [0,1]`
while writing nothing; the row was then restored to 0–1. The preview never wrote.

**Stale-status check:** `select count(*) from matches where status='scheduled' and
kickoff_at < now()` → **0**. No fixture is past kickoff without a result.

### 21.4 Prospective capture status

`scripts/prospective_readiness.py` (read-only):

| Metric | Value |
| --- | --- |
| predictions stored | 222 |
| with `model_freeze_digest` | 155 |
| with `feature_version` | 155 |
| legacy rows (no provenance, permanently ineligible) | 67 |
| live predictions on future fixtures | **15 fixtures, 70 rows** (10 with a verified digest) |
| issued at/after kickoff (never evidence) | 10 |
| evaluation records written | **0** |
| currently scorable | 0 |

**Correction to §20.** §20 reported 189 predictions. The database holds **222**: the
§20 pipeline sweep issued 55 (11 fixtures × 5 markets) and a later verification run
issued 5 more for match 39641, which §20's count did not include. The 12 fixtures
carrying live predictions are 40510 (T1), 40348 (N1), 40189 (D1), 40243 (I1),
40303 (F1), 39663 (E0), 40072 (SP1), 40456 (P1), 40133 (SC0) — the ten issued by
the §20 sweep, all with a verified digest — plus 39641, 4357, 4361, 4363, 4366 and
4280, which are older rows without provenance and will stay ineligible.

**The ten with a digest are the first genuine prospective candidates in the
project's history.** They become evidence only when their fixtures complete and
`rake predictions:sweep APPLY=1` scores them. The earliest kickoff is 2026-11-06.

**Verdict: infrastructure READY, evidence INSUFFICIENT.** The 10 late predictions
are the ones §20 documented; they are stored, refused by the gate, and must never be
counted. No prediction was fabricated and no timestamp was backfilled.

### 21.5 Odds provider findings (football-data.co.uk, measured)

All 11 competitions, free, no account, **1X2 and O/U 2.5 only**, with both a
pre-match and a closing snapshot. **No BTTS, no Double Chance, no Correct Score.**
**No capture timestamp** — which is the decisive limitation: it cannot prove what
price existed when a prediction was issued, so it cannot support a paper-trading
ledger. It can support a retrospective diagnostic and a closing-line reference.

**Historical odds coverage is not live odds availability.** A timestamped provider
is required for paper trading and has not been selected. Full table in
`docs/betting_intelligence_design.md` §12.

### 21.6 Paper-trading foundation (built, pure, no persistence)

| Component | Purpose |
| --- | --- |
| `Odds::OddsMath` | overround, de-vig, EV, CLV, decimal-odds validation |
| `Odds::MarketMatching` | provider names → our markets; football-data column families |
| `Odds::PaperBet` | immutable would-be bet, settlement, portfolio summary |

**Double Chance is refused by `de_vig`** (`NotAPartition`), and the market is
inferred from the selection keys so a caller that omits `market:` cannot get a
silently normalised result. Double Chance fair probabilities must come from the
de-vigged 1X2.

No table was created and no odds data entered the database. The implementation plan
(7 steps, each gated) is in `docs/betting_intelligence_design.md` §12.4.

### 21.7 Tests

| Suite | Command | Result |
| --- | --- | --- |
| Backend (full) | `docker compose exec -T web bundle exec rspec` | **1173 examples, 0 failures, 1 pending** |
| — new this phase | `spec/services/sync/espn_result_synchronizer_spec.rb` | 18 examples |
| — new this phase | `spec/services/odds/` (3 files) | 55 examples |
| ML | `docker compose exec -T ml sh -c 'cd /app/ml && python -m pytest tests/ -q'` | **354 passed** |
| Mobile types | `npx tsc --noEmit` | exit 0 |
| Mobile tests | `npx jest` | **148 passed** |

The pending example is the documented match-4280 skip.

### 21.8 Database changes

**None to the schema.** No migration was written or run in this phase.

Data written: `sync_runs` rows only — 49 preview runs and 2 apply runs from the
dry-run sweep, plus the ledger rows from the conflict verification. **No match,
prediction or evaluation record was created, changed or deleted.** The prediction
count moved from 189 to 222 because of the §20 verification runs described in
21.4, not because of anything in this phase.

**One incident, disclosed:** while debugging a spec I ran a `rails runner` snippet
that created a temporary competition, season, two teams and one match in the
**development** database. It was detected immediately and removed by primary key
(competition 17, season 140, teams 350–351, the one match). Verified afterwards:
11 competitions, 41,970 matches, 189 predictions — the pre-incident counts. The
lesson is recorded rather than hidden: debug snippets must run inside a transaction
that is rolled back, which is what the later conflict check did.

### 21.9 Outstanding approval requirements

1. **Scheduling `results:sync`.** The task is manual by design. Enabling it on a
   timer (or registering `SyncResultsJob`) is a policy decision — cadence, and who
   reads the conflict list — and has not been made.
2. **Odds ingestion.** Step 1 of the plan (an `odds_snapshots` table) needs a
   migration approval; step 2 (football-data importer) needs a data-download
   approval. Neither has been requested beyond this document.
3. **A live timestamped odds provider.** Required before paper trading can produce
   evidence. Needs budget and account approval; nothing was contacted.
4. **Calibration fitting.** Still unauthorised.
5. **The 10 late predictions.** They remain stored and ineligible. Deleting them
   would be a data change and is not proposed; they are evidence of a process gap,
   not of a model.

### 21.10 Readiness

| Question | Answer |
| --- | --- |
| Result collection infrastructure | **READY** (preview + apply, conflicts surfaced, audited) |
| Prospective capture infrastructure | **READY** |
| Prospective evidence | **NONE** |
| Odds data | **NONE** |
| Paper trading | **NOT POSSIBLE** — no timestamped prices |
| Betting readiness | **NO** |

**INSUFFICIENT EVIDENCE — NO BETTING RECOMMENDATION.**
## 22. Mobile match UX fixes — results ordering and completed Match Details (2026-11-04)

Scope: `mobile/` only. **No backend change, no schema change, no migration, no
prediction logic change.** No commit, no push (HEAD still `0c42db6`). Phase D2 was
not continued.

### 22.1 Defect 1 — completed Match Details rendered an empty screen

**Root cause.** `app/matches/[id].tsx` resolved the match **only** from
`useMatches({ status: 'scheduled', limit: 2000 })`:

```tsx
const match = useMemo(
  () => upcomingQuery.data?.find((candidate) => candidate.id === matchId),
  [upcomingQuery.data, matchId],
);
```

A completed fixture is not in the scheduled set, so `match` was `undefined` and the
screen fell through to `<EmptyState title="Match not found">`. The list screens
already pass the full match object as a JSON navigation param (`params.match`), and
the screen parsed it into `passed` — then never used it. Upcoming matches appeared
to work only because they happen to be in the scheduled set.

**Fix.** The passed match is now the primary source, with the id checked so a stale
param cannot display a different match than the route names; the query remains the
deep-link fallback. A failed fallback query is only an error when it was the only
source — an unrelated list failure must not replace a match the user just opened.

```tsx
const match = useMemo(() => {
  if (passed && passed.id === matchId) return passed;
  return upcomingQuery.data?.find((candidate) => candidate.id === matchId);
}, [passed, upcomingQuery.data, matchId]);
```

**Regression test.** `__tests__/screens/matchDetail.test.tsx` (14 examples), written
first. Before the fix **all 14 failed** — including the upcoming-match cases, which
proved the passed match was ignored entirely, not merely mishandled for completed
fixtures. After the fix: 14/14.

Covered: completed match renders; both team names; final score `0 - 1`; competition
and season; status ("Full time"); Generate Prediction disabled for a completed
match; rendering does not depend on the scheduled list; upcoming match still renders
with kickoff instead of a score and an enabled button; deep-link fallback; invalid
id; API error is not shown as "Match not found"; genuinely missing match says so.

### 22.2 Defect 2 — completed results listed oldest-first

**Where the ordering came from: the Rails API, and it is correct there.**
`GET /api/v1/matches` orders `kickoff_at ASC, id ASC` and applies `limit` **after**
ordering. Reversing it server-side would return the *oldest* rows of a capped page
and would change the contract for the ML service and the upcoming list. The ordering
is therefore a presentation concern.

**Fix.** New pure module `src/domain/matchOrdering.ts` exporting
`orderMatchesForDisplay(matches, status)`, used by both list screens
(`app/(tabs)/fixtures/index.tsx` and `app/competitions/[id].tsx`).

| Rule | Behaviour |
| --- | --- |
| Completed lists | newest kickoff first, then highest id |
| Upcoming lists | unchanged — server ascending order, same array instance returned |
| Unfiltered lists | unchanged — mixing two directions has no correct answer |
| Missing / unparseable kickoff | sorts **last**, then by id descending |
| Input | never mutated |

A missing date sorts last rather than first because an unknown date is not evidence
of a recent match, and putting it on top would push a real result off the first
screen. A comparator returning `NaN` for either side leaves the sort
implementation-defined, so both sides are handled explicitly.

**Regression test.** `__tests__/domain/matchOrdering.test.ts` (14 examples), written
first and failing on the missing module. Includes a case where ids run opposite to
kickoff order, so a sort by id would pass a naive test but fail this one.

**Verified against real data.** The live API page for E0 2026/27 completed matches
returns `2678 (2026-08-21) … 39662 (2026-11-02)`; the ordering function reverses it
to `39662, 39661, 39660, 2679, 2678` — latest first, oldest last.

### 22.3 Files changed

| File | Change |
| --- | --- |
| `mobile/app/matches/[id].tsx` | passed match is the primary source; fallback error only when it is the only source |
| `mobile/src/domain/matchOrdering.ts` | **new** — display ordering rule |
| `mobile/app/(tabs)/fixtures/index.tsx` | applies the ordering |
| `mobile/app/competitions/[id].tsx` | applies the ordering |
| `mobile/__tests__/domain/matchOrdering.test.ts` | **new** — 14 examples |
| `mobile/__tests__/screens/matchDetail.test.tsx` | **new** — 14 examples |

### 22.4 Test results (executed)

| Check | Command | Result |
| --- | --- | --- |
| New ordering tests | `npx jest __tests__/domain/matchOrdering.test.ts` | **14 passed** (failed before implementation) |
| New detail tests | `npx jest __tests__/screens/matchDetail.test.tsx` | **14 passed** (all 14 failed before the fix) |
| Full mobile suite | `npx jest` | **176 passed, 15 suites** (was 148 / 13) |
| TypeScript | `npx tsc --noEmit` | **exit 0, 0 errors** |
| Android bundle | `npx expo export --platform android` | **exit 0**, `entry-*.hbc` 3.7 MB |
| Rails | not run | no backend change was made |

### 22.5 Integrity

| Check | Result |
| --- | --- |
| Git | no commit, no push, no branch change |
| Database | untouched — no query wrote anything |
| Predictions / evaluation records | unchanged |
| Model artifacts | untouched |
| Sidekiq / cron | still stopped |
| Backend / ML code | unchanged |

### 22.6 Remaining limitations

1. **No device run.** No Android SDK/AVD on this host; the evidence is a green
   suite, a zero-error type check and a compiling bundle.
2. **No pagination exists** on either list screen (`limit: 500`, single page), so
   "pages must not reverse or duplicate" is satisfied trivially — there are no
   pages. If pagination is added later, the ordering must be applied to the
   accumulated list, not per page, or the boundary between pages will be wrong.
3. **The `limit: 500` cap** means a season with more than 500 completed matches
   would silently truncate. E0 2026/27 currently has 107, so it is not hit today.
4. **Deep links to a completed match still fail** — there is no
   `GET /api/v1/matches/:id`, and the scheduled fallback cannot find a completed
   fixture. Fixing that needs a backend endpoint, which was out of scope here.
## 23. Per-match result checking — individual job (2026-11-05)

Scope: the **individual result-check job only**. The dispatcher and the recurring
schedule are **not implemented** (see 23.7). No commit, no push (HEAD `0c42db6`).
Sidekiq not started. No live provider import. Database unchanged: 41,970 matches,
222 predictions, 0 evaluation records.

### 23.1 What already existed, and what was missing

| Component | State found | Used |
| --- | --- | --- |
| `Import::EspnClient` | `scoreboard`, `scoreboard_dates`, `teams` — **no event lookup** | extended |
| `Import::EspnAdapter` | event → canonical row, status precedence | reused unchanged |
| `Import::ApiFootballReconciler` | identity, duplicates, conflict precedence | reused unchanged |
| `Sync::EspnResultSynchronizer` | **date-scoped** `call`/`preview` only | extended with `check_event` |
| `Sync::SyncRun` | ledger, kind `results` | reused unchanged |
| `SidekiqCronSchedule` | 4 entries, none for result checking | untouched |

**The synchronizer did not support single-match retrieval.** `call(league:, season:,
date:)` fetches a whole scoreboard day and iterates every event, so checking one
fixture would touch every other match on that day.

### 23.2 The ESPN endpoint

`GET https://site.api.espn.com/apis/site/v2/sports/soccer/{league}/summary?event={id}`

Returns the event under `header.competitions[0]` — the same shape the adapter
already parses. `Import::EspnClient#event(league:, event_id:)` attaches the event id
(the summary payload does not repeat it inside the competition) and reuses
`perform`/`decompress`/the existing error classes. A **404 is permanent**
(`InvalidContentError`), not transient: retrying it is a retry storm against a free
endpoint.

### 23.3 The single-match path

`Sync::EspnResultSynchronizer#check_event(event_payload:, match:, season:, apply:)`
reuses `decide`, `classify` and the reconciler's `planned_changes`, and adds two
guards the date-scoped path does not need:

1. **Association** — the event must resolve to the match the caller asked about.
2. **Team agreement** — the payload's clubs, resolved through approved mappings,
   must be the stored fixture's clubs.

Guard 2 was added after a test proved guard 1 insufficient: `resolve_match` matches
by **provider id first**, so an event whose id is linked to the match but whose
payload describes different clubs still resolved to it. The id is a claim; the teams
are the evidence.

The write is performed against the verified row under `with_lock`, not through
`apply_fixture` (which re-resolves by provider id and would write to whatever it
found).

### 23.4 The job

`MatchResultCheckJob#perform(match_id, attempt = 1)`:

| Step | Behaviour |
| --- | --- |
| Reload | `Match.find_by`; a missing match is recorded, not raised |
| Completed match | recorded `ineligible` — **no provider request** (see 23.5) |
| Eligibility | status, unknown kickoff, retry window, completion buffer — in that order |
| Event id | approved `ExternalIdentifier` for the match |
| League | `EspnLeagueCoverage::VERIFIED[competition.code]` |
| Fetch | exactly one event |
| Apply | `check_event` |
| Record | one `sync_runs` row per attempt with match id, event id, attempt, outcome, status, score, conflicts |
| Retry | `unchanged` or transient error → re-enqueue after 30 min, until 24 h past kickoff |

**Retry-window termination** is reported as `unresolved`, not `ineligible`: a match
past the window needs a human, one that is merely not due yet needs time, and
collapsing the two would hide fixtures that will never resolve on their own.

### 23.5 A design decision, stated explicitly

A **completed** match is not re-fetched. The reconciler would refuse to change it
anyway, the dispatcher never selects one, and a conflict on an already-completed
match is detected by the date-scoped `results:sync` run, which compares whole days.
The job records `ineligible` with the reason `match is completed`. The overwrite
guarantee itself is asserted at the layer that owns it — the synchronizer — and the
job's behaviour is asserted separately.

### 23.6 Tests — actual results

```
docker compose exec -T web bundle exec rspec spec/jobs/match_result_check_job_spec.rb
20 examples, 0 failures
PIPELINE_EXIT=0

docker compose exec -T web bundle exec rspec
1193 examples, 0 failures, 1 pending
PIPELINE_EXIT=0
```

The pending example is the documented match-4280 skip.

Covered: provider access (one event, never a scoreboard; no call when ineligible);
final result applied; in-progress recorded without a score; pre-match unchanged;
`completed: true` with a non-final status not treated as a result; postponed,
cancelled, abandoned, suspended; completed match not re-fetched; no fixture created;
event resolving to a different match refused; no predictions created; timeout leaves
the match untouched and records `provider_error`; idempotent second run; retry window
termination.

**Defects found by the tests, not by inspection:**

1. `single()` omitted the required `league:` keyword — every rejection path raised
   `ArgumentError` instead of returning a Report.
2. The association guard was bypassable via provider-id resolution (23.3).
3. The retry window was reported as `ineligible` rather than `unresolved`.
4. `perform_later` forwards its arguments to `new` in this ActiveJob version, so the
   constructor must accept and ignore them, and `super()` is required or
   `Arguments.serialize` calls `.map` on a nil `@arguments`.

### 23.7 Not implemented — the dispatcher and the schedule

Deliberately out of scope for this step. When built, the dispatcher must select
`scheduled` matches with kickoff ≥ 2 h 15 m in the past, an approved ESPN event id,
no trusted result, and not already queued — and must not call ESPN itself.

### 23.8 Known limitations

1. **No dispatcher**, so nothing enqueues this job yet.
2. **No deduplication** across concurrent enqueues; that belongs to the dispatcher.
3. **`STATUS_SUSPENDED` maps to `in_progress`** in the adapter, so a suspended match
   is retried until the window closes rather than being flagged immediately.
4. **The summary endpoint was not exercised against live ESPN** in this session —
   the tests use fake payloads, and no live import was run.
5. **A conflict on an already-completed match is not detected here** (23.5).
## 24. Result-check dispatcher and cross-enqueue deduplication (2026-11-05)

Completes the automated per-match result-checking pipeline. **Recurring execution is
configured but NOT activated.** No commit, no push (HEAD `0c42db6`). Sidekiq not
started. No live import. Database unchanged: 41,970 matches, 222 predictions,
0 evaluation records.

### 24.1 Architecture

```
SidekiqCronSchedule  ──(every 5 min, NOT ACTIVE)──▶  MatchResultDispatchJob
                                                          │  database query only
                                                          │  no ESPN request
                                                          ▼
                                              Sync::ResultCheckLock.acquire(match)
                                                          │  one per eligible match
                                                          ▼
                                                  MatchResultCheckJob
                                                          │  ONE ESPN event
                                                          ▼
                                        Sync::EspnResultSynchronizer#check_event
```

The split is the point: the dispatcher answers *which matches are due* (a database
question), the job answers *what happened in this one match* (a provider question).
A provider outage cannot stop the queue from being filled, and a five-minute
dispatcher cadence costs no ESPN quota.

### 24.2 Eligibility rules

| Rule | Value |
| --- | --- |
| Status | `scheduled` only |
| Kickoff | at least 2 h 15 m in the past (`COMPLETION_BUFFER`) |
| Kickoff | within 24 h (`MAX_RETRY_WINDOW`) — past it the match is `expired` |
| ESPN event id | must exist and be `review_state = approved` |
| Competition | must map to a verified ESPN league |
| Lock | must be acquirable |

The retry window is checked **before** the completion buffer, so a match past the
window is reported `expired` (needs a human) rather than "not due yet".

### 24.3 Deduplication

`Sync::ResultCheckLock` — a **PostgreSQL advisory lock** per match.

| Property | How |
| --- | --- |
| Atomic | `pg_try_advisory_lock` |
| Cross-process | lives in PostgreSQL, not in Ruby |
| Crash recovery | the lock dies with its connection |
| Hung worker | `ttl` (15 min) is honoured on re-acquisition |
| Retry eligibility | the job releases on completion, so the next dispatch re-enqueues |
| Observability | `result_check_locks` row records holder and expiry |

**A dedicated PG connection per lock, not a pooled one.** The first implementation
checked out a Rails pool connection and held it for the duration of the check; the
lock spec exhausted the pool immediately. The lock now opens its own short-lived
connection, which also makes crash recovery automatic.

**The bookkeeping table is not the lock.** `result_check_locks` exists so an operator
can see who holds what; a stale row there can never block a check, because the
advisory lock is the authority.

### 24.4 Retry and terminal states

| Situation | Outcome recorded | Retry |
| --- | --- | --- |
| Final result | `completed` | no |
| In progress / suspended | `unchanged` | yes, 30 min |
| Postponed / cancelled | `postponed` | no |
| Rescheduled | `rescheduled` | no |
| Event/club mismatch | `rejected` | no |
| Transient provider error | `provider_error` | yes, 30 min |
| Permanent provider error (404) | `provider_error` | no |
| Past 24 h window | `unresolved` | no |
| Completed match | `ineligible` | no |

### 24.5 Scheduling — configured, NOT active

Added to the existing `SidekiqCronSchedule` (no second scheduler):

```ruby
'result_check' => {
  name: 'match_result_dispatch',
  cron: '*/5 * * * *',
  class: 'MatchResultDispatchJob',
  description: 'Per-match ESPN result checking: enqueue one check per due match'
}
```

**Activation requires all of the following, and none has been done:**

1. Start the Sidekiq worker: `docker compose up -d sidekiq`.
2. The worker calls `SidekiqCronSchedule.register!` at boot, which registers
   `match_result_dispatch` alongside the four existing entries.
3. Verify with `Sidekiq::Cron::Job.all` that exactly one `match_result_dispatch`
   entry exists.

**Do not start the worker before deciding what happens to the other four entries** —
`sync_fixtures`, `sync_results`, `sync_espn_discovery` and `api_football_live` are
registered by the same call and would begin writing immediately (handout §8.6).

### 24.6 Tests — actual results

```
docker compose exec -T web bundle exec rspec spec/jobs/match_result_check_job_spec.rb \
  spec/jobs/match_result_dispatch_job_spec.rb spec/jobs/result_check_integration_spec.rb \
  spec/services/sync/result_check_lock_spec.rb
51 examples, 0 failures
PIPELINE_EXIT=0

docker compose exec -T web bundle exec rspec
1225 examples, 0 failures, 1 pending
PIPELINE_EXIT=0
```

The pending example is the documented match-4280 skip.

New coverage: dispatcher eligibility (future, buffer, no id, unapproved id, unmapped
competition, completed, expired, empty set, multiple competitions), enqueue counts,
no ESPN call, ledger row, database error handling; lock acquisition, refusal,
independence, concurrency, release, expiry recovery, retry re-acquisition;
integration (only the intended match updated, in-progress unchanged, postponed not
completed, trusted result untouched, club mismatch rejected, no fixtures or
predictions, no duplicate enqueue).

**Defects found by the tests:**

1. Holding a pooled connection for the lock exhausted the connection pool.
2. An expired lock held by the same process was never released, so a hung worker
   could block its own match forever.
3. The existing schedule spec asserted every entry runs daily; the dispatcher is a
   deliberate sub-daily exception and the spec now names both exceptions explicitly.

### 24.7 Known limitations

1. **Not activated.** Nothing runs until the worker is started (24.5).
2. **`BATCH_SIZE = 200`** per dispatch. A backlog larger than that drains over
   several five-minute runs.
3. **The lock is per process for `locked?`** — a second process sees the advisory
   lock only through the bookkeeping row, which is advisory, not authoritative.
4. **No dispatcher-level metric endpoint**; the summary lives in `sync_runs.details`.
5. **The ESPN summary endpoint has still not been exercised against live ESPN.**
   All tests use fake payloads.
## 25. Isolated dispatcher activation readiness (2026-11-05)

Prepares the result dispatcher for safe, isolated activation. **Nothing was
activated.** No commit, no push (HEAD `0c42db6`). Sidekiq not started. Redis holds
**0** cron entries. Database unchanged: 41,970 matches, 222 predictions,
0 evaluation records, 0 lock rows.

### 25.1 Correction: the TTL claim in §24.3 was wrong

§24.3 said a 15-minute TTL recovers a hung worker. **A PostgreSQL session-level
advisory lock does not expire.** Measured directly against the running database:

```
holder:  SELECT pg_try_advisory_lock(999005); SELECT pg_sleep(8);
t=1s     second session: pg_try_advisory_lock(999005) -> f
t=8s     second session: pg_try_advisory_lock(999005) -> f   (holder still alive)
```

The lock is held until the session ends or is explicitly released. A timestamp in
a bookkeeping table releases nothing.

An earlier probe appeared to show expiry; it was wrong because `psql -c` closes its
session immediately, releasing the lock. The lesson is recorded because it is the
same trap that produced the original claim.

### 25.2 What actually recovers a lock

| Failure | Recovery mechanism |
| --- | --- |
| Worker process dies | its connection closes; PostgreSQL releases the lock with the session |
| Worker hangs but stays alive | the TTL: the next acquirer **terminates the stale holder's backend** (`pg_terminate_backend`), which is the only way to break a session lock held by a live session |
| Worker raises | the job's `ensure` releases; the connection closes regardless |
| Process forgets it held a lock | `abandon!` closes the connection, which releases the lock |

The TTL is therefore a **takeover deadline**, not an expiry. `locked?` reports an
expired lock as not live, and `acquire` takes it over.

### 25.3 Connection-pool safety

The lock uses a **dedicated `PG` connection**, never one from the ActiveRecord pool.
Verified by test: acquiring a lock does not change the pool's in-use count, the pool
stays usable while a lock is held, and the dedicated connection is `finished?` after
release. A session lock can therefore never leak into a pooled connection.

### 25.4 Scheduler registration modes

`SIDEKIQ_CRON_MODE` selects what a worker registers at boot:

| Mode | Registers |
| --- | --- |
| `disabled` (**default**) | nothing |
| `result_dispatch_only` | `match_result_dispatch` only |
| `all` | all five entries |

**An unknown value resolves to `disabled`**, and `mode_warning` names the bad value
so the boot log shows the mistake. A typo must fail towards "nothing runs", never
towards "every job runs".

`register!` registers only the selected entries and **never removes** entries it did
not register — an operator's hand-added entry survives, and removal is a destructive
act that does not belong in a boot hook.

### 25.5 Tests — actual results

```
spec/services/sync/result_check_lock_spec.rb     17 examples, 0 failures
spec/jobs/match_result_dispatch_job_spec.rb      16 examples, 0 failures
spec/config/ (schedule + mode)                   25 examples, 0 failures
full suite                                     1251 examples, 0 failures, 1 pending
PIPELINE_EXIT=0
```

The pending example is the documented match-4280 skip.

**Cross-process locking is proven with a real second PostgreSQL session**, not a
second call in the same process: a separate `PG.connect` is refused while the lock
is held and succeeds after release. The pool-safety and crash-recovery tests use the
same real connections.

### 25.6 Activation procedure (NOT executed)

```bash
# 1. Set the mode for the worker only. Do not put this in .env unless you intend
#    every future worker start to use it.
SIDEKIQ_CRON_MODE=result_dispatch_only

# 2. Start the worker (NOT DONE — requires explicit authorisation)
docker compose up -d sidekiq

# 3. Verify exactly one entry is registered
docker compose exec -T redis redis-cli --scan --pattern 'cron_job*'
#   expect exactly: cron_job:match_result_dispatch

# 4. Verify the boot log
docker compose logs sidekiq | grep sidekiq-cron
#   expect: mode=result_dispatch_only: registered match_result_dispatch
```

**Why the other four stay dormant:** `register!` filters by mode, so
`sync_fixtures`, `sync_results`, `sync_espn_discovery` and `api_football_live` are
never written to Redis. They remain defined in `ENTRIES` and reviewable, but
unregistered.

### 25.7 Remaining activation risks

1. **The mode is process-wide.** A worker started without the variable registers
   nothing — safe, but silent unless the boot log is read.
2. **`pg_terminate_backend` on takeover** kills the stale holder's session. If that
   session is doing unrelated work on the same connection, that work is lost. The
   lock's connection is dedicated, so in practice it holds nothing else.
3. **The ESPN summary endpoint has still never been exercised against live ESPN.**
   Every test uses fake payloads. The first live run is the real test.
4. **No dispatcher metric endpoint**; the summary lives in `sync_runs.details`.
5. **`BATCH_SIZE = 200`** per run; a larger backlog drains over several runs.

### 25.8 Confirmation

No worker, scheduler, cron entry or recurring job was started. No live import, no
prediction, no model change. Redis cron entries: **0**.
## 26. Authorized isolated Sidekiq activation — and four defects it exposed (2026-11-05)

The user authorized `SIDEKIQ_CRON_MODE=result_dispatch_only docker compose up -d
sidekiq`. **The worker is now running with exactly one registered job.** No commit,
no push (HEAD `0c42db6`).

The activation was not a formality: it exposed **four defects that every unit test
had missed**, because the tests call `perform` directly and never exercise a real
enqueue round-trip.

### 26.1 Pre-start: the authorized command would have registered nothing

`docker-compose.yml` lists `environment:` explicitly and did not include
`SIDEKIQ_CRON_MODE`. A shell-prefixed variable is **silently dropped** by Compose, so
the worker would have booted with the variable absent → `disabled` → **no jobs at
all**. Verified before starting:

```
SIDEKIQ_CRON_MODE=result_dispatch_only docker compose run --rm sidekiq env | grep -c SIDEKIQ_CRON_MODE
0
```

Fixed by adding one line to the sidekiq service, defaulting to `disabled`:

```yaml
SIDEKIQ_CRON_MODE: ${SIDEKIQ_CRON_MODE:-disabled}
```

### 26.2 Defect 1 — arguments were swallowed by the constructor

First live run: four jobs enqueued, **all four died** with

```
ArgumentError: wrong number of arguments (given 0, expected 1..2)
app/jobs/match_result_check_job.rb:68:in `perform'
```

The Sidekiq payload carried `"arguments": []`. The constructor accepted the perform
arguments via `*_args` and called `super()` with **no arguments**, so ActiveJob's
`@arguments` stayed empty and nothing was serialised.

**Why the specs missed it:** every job spec calls `perform` on an instance, which
never serialises. Fixed by `super(*args)`, and pinned by
`spec/jobs/job_argument_round_trip_spec.rb`, which goes through
`job.serialize` and `ActiveJob::Base.execute`.

### 26.3 Defect 2 — concurrent checks lost their ledger rows

The first check recorded a row; the rest raised
`Sync::SyncRun::AlreadyRunning: a results synchronization is already running`.
`sync_runs` allows **one `running` row per kind**, which is right for the daily
synchronizations and wrong for per-match checks.

Fixed with a new `match_check` kind **and** a rebuilt partial unique index that
excludes it:

```sql
CREATE UNIQUE INDEX index_sync_runs_one_running_per_kind
  ON sync_runs (kind) WHERE status = 'running' AND kind <> 'match_check';
```

The daily kinds keep their single-run guarantee. `SyncRun::SCHEDULED_KINDS` was
added so the status endpoint and `status_summary` keep reporting only the two
scheduled kinds — otherwise the new kind would have changed the API response shape
and reported a permanent "degraded".

### 26.4 Defect 3 — every event was "unusable payload"

All checks recorded `rejected` with reason `unusable payload`. The ESPN summary
endpoint nests the competition under `header`, and `EspnClient#event` returned that
bare competition — but `EspnAdapter#normalize_fixture` reads `payload['competitions']`,
because that is how a **scoreboard** event is shaped.

Fixed by returning the scoreboard event shape. Pinned by
`spec/services/import/espn_client_event_spec.rb`, which uses the real summary
structure and asserts the adapter can normalise it.

### 26.5 Defect 4 — locks were never released

After the first successful run, **four advisory locks and four bookkeeping rows
remained**. The dispatcher acquired the lock; nothing released it. Each would have
blocked its match until the 15-minute TTL takeover.

Fixed with an `ensure` in `MatchResultCheckJob#perform` that releases the lock on
every path — success, early return, and exception. Pinned by two specs in
`match_check_ledger_spec.rb`.

### 26.6 Verified live behaviour

| Check | Result |
| --- | --- |
| Registered cron jobs | **1** — `match_result_dispatch` |
| `sync_fixtures` / `sync_results` / `sync_espn_discovery` / `api_football_live` | **absent** |
| Boot log | `mode=result_dispatch_only: registered match_result_dispatch` |
| First dispatch | 10:50:48 UTC — 4 considered, 4 eligible, 4 enqueued, 0 errors |
| Second dispatch | 11:15:20 UTC — 4 considered, 4 eligible, 4 enqueued, 0 errors |
| Third dispatch | 11:20:11 UTC — 0 considered (all four now completed) |
| Individual checks | 4 × `completed`, each one ESPN event, real scores applied |
| Locks after the final cycle | **0 rows, 0 advisory locks** |
| Matches | 41,970 → **41,970** (no fixture created) |
| Predictions | 222 → **222** (none created) |
| Evaluation records | 0 → **0** |

The four matches completed by the live run were genuine results for fixtures that
had kicked off more than 2h15m earlier and had no stored result.

### 26.7 Tests — actual results

```
spec/jobs/job_argument_round_trip_spec.rb     4 examples, 0 failures
spec/jobs/match_check_ledger_spec.rb          6 examples, 0 failures
spec/services/import/espn_client_event_spec.rb 5 examples, 0 failures
full suite                                 1266 examples, 0 failures, 1 pending
PIPELINE_EXIT=0
```

### 26.8 A hazard worth recording

The test suite's `after(:suite)` hook **destroys the cron entries in the live
Redis**. While the worker was running, a test run removed its schedule; the worker
kept running but stopped dispatching until restarted. This is not a production
concern (tests do not run against production Redis) but it is a real trap in
development: **do not run the suite while relying on the worker's schedule**, or
restart the worker afterwards.

### 26.9 Current state

- Sidekiq: **running**, `SIDEKIQ_CRON_MODE=result_dispatch_only`.
- Registered: `match_result_dispatch` only, every 5 minutes.
- The other four jobs remain defined but unregistered.
- No predictions, no odds, no model change, no bets.

### 26.10 Remaining risks

1. **The mode is process-wide and silent if unset** — a worker started without the
   variable registers nothing (safe, but quiet).
2. **The suite clears the live cron schedule** (26.8).
3. **`pg_terminate_backend` on TTL takeover** kills the stale holder's session.
4. **No dispatcher metric endpoint**; the summary lives in `sync_runs.details`.
5. **`BATCH_SIZE = 200`** per run.
