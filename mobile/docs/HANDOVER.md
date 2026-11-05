# Mobile handover — implementation report

Status: MVP implemented and verified against the live Rails backend.
Scope: `mobile/` only. `backend/`, `ml/`, `docs/` and all shared files were not
modified in this session. Nothing was committed or pushed.

Companion document: `mobile/docs/ARCHITECTURE.md` (decisions AD-1…AD-12,
debt D-1…D-10).

---

## 1. Files

### Created

```
mobile/docs/ARCHITECTURE.md
mobile/docs/HANDOVER.md
mobile/jest.config.js
mobile/jest.setup.ts
mobile/app/_layout.tsx                    root Stack + providers
mobile/app/(tabs)/_layout.tsx             tab navigator
mobile/app/(tabs)/index.tsx               Dashboard
mobile/app/(tabs)/fixtures/index.tsx      Fixtures
mobile/app/(tabs)/system.tsx              System status
mobile/app/matches/[id].tsx               Match detail + predictions
mobile/src/theme/theme.ts
mobile/src/types/api.ts
mobile/src/config/environment.ts          (Kilo file, retained as-is)
mobile/src/services/api/client.ts         (Kilo file, rewritten — see §2)
mobile/src/services/api/endpoints.ts
mobile/src/services/api/errors.ts
mobile/src/services/api/queryKeys.ts
mobile/src/hooks/useApi.ts
mobile/src/domain/predictions.ts
mobile/src/domain/selection.ts
mobile/src/utils/format.ts
mobile/src/components/AppProviders.tsx
mobile/src/components/ScreenState.tsx
mobile/src/components/ProbabilityBar.tsx
mobile/src/components/MarketCard.tsx
mobile/src/components/MatchCard.tsx
mobile/src/App.tsx (Kilo template, unused)
mobile/__tests__/config/environment.test.ts
mobile/__tests__/services/apiError.test.ts
mobile/__tests__/services/endpoints.test.ts
mobile/__tests__/domain/predictions.test.ts
mobile/__tests__/domain/selection.test.ts
mobile/__tests__/hooks/apiHooks.test.tsx
mobile/__tests__/utils/format.test.ts
mobile/__tests__/components/MarketCard.test.tsx
```

### Modified

| File                                | Change                                         | Why                                                                                                                 |
| ----------------------------------- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `mobile/package.json`               | `main` → `expo-router/entry`; scripts added    | The app had the router plugin configured but was still booting the single-component `App.tsx`, so no route existed. |
| `mobile/app.json`                   | `expo-router` plugin given `{ root: './app' }` | Without it the SDK resolved the router root to the (empty) `src/app` and every route 404'd.                         |
| `mobile/tsconfig.json`              | removed `baseUrl`                              | Deprecated in TypeScript 7; `moduleResolution: bundler` resolves `paths` without it.                                |
| `mobile/src/services/api/client.ts` | rewritten                                      | Kilo's version read `data.message`, but Rails sends `{ error }`, so every message degraded to Axios' generic text.  |

### Deleted (empty directories only)

`src/app`, `src/components/{common,competitions,fixtures,layout,predictions}`,
`src/constants`, `src/features` — Kilo scaffolding with no files in them. The
empty `src/app` was actively harmful: it is what the router resolved to.

### Added dependencies

`expo-router`, `axios`, `@tanstack/react-query`, `react-native-paper`,
`@expo/vector-icons`, `expo-font`, and via `npx expo install`: `react-native-safe-area-context`,
`react-native-screens`, `expo-linking`, `expo-constants`, `react-native-web`,
`react-dom`, `@expo/metro-runtime`. Dev: `jest`, `jest-expo`,
`@testing-library/react-native`, `@types/jest`, `zod`, `react-hook-form`.

**Why they were missing:** Kilo reported installing Axios, TanStack Query, React
Hook Form, Zod, React Native Paper and vector icons. None of them were in
`package.json`, and there was no lockfile and no `node_modules`. This also
explains the follow-up report that "Axios was missing" — it was never installed.

`expo-font` was added because `expo-doctor` flagged it: Expo Router requires it
as a native peer, and the app would fail outside Expo Go.

---

## 2. Dependency manifest

Expo SDK **58.0.21**, React Native **0.83.x**, React **19.x**, `expo-router` 58.
`expo install --fix` was run to align versions; `expo-doctor` → **20/20 checks
passed**.

Lockfile: `mobile/package-lock.json` (npm). It did not exist before this session.

---

## 3. API integration, verified against `docs/api-contracts.md`

| Contract point                                           | Implementation                                                      | Verified live                |
| -------------------------------------------------------- | ------------------------------------------------------------------- | ---------------------------- |
| Base URL from `EXPO_PUBLIC_API_BASE_URL`, versioned once | `client.ts` `baseURL` = host only; `endpoints.ts` carries `/api/v1` | Yes                          |
| `POST` takes `match_id` in the **body**                  | `useRequestPredictions` posts to `/api/v1/predictions`              | Yes — Rails persisted 4 rows |
| `GET /api/v1/predictions/:id` uses the **match** id      | `endpoints.predictionsForMatch`                                     | Yes                          |
| 201 / 207 share one shape; 207 is partial                | `mergePartialPredictionResponse` sets `partial`                     | Unit-tested                  |
| Legacy fields ignored for non-1X2                        | `MarketCard` reads only `probabilities` + `selection`               | Regression test + live       |
| Double Chance derived from 1X2                           | `deriveDoubleChance`                                                | Live: 1X = H+D               |
| 404 on predictions = empty state                         | `isNotFound` (structural status check)                              | Unit-tested                  |
| `{"error": "..."}` error format                          | `normalizeApiError`                                                 | Yes                          |
| No authentication                                        | none sent                                                           | Yes                          |
| No pagination; `limit` caps                              | filters serialised, absent ones omitted                             | Yes                          |

**A defect was introduced and then found by live testing:** `baseURL` already
ended in `/api/v1` _and_ every endpoint path included it, so every request went
to `/api/v1/api/v1/...` and 404'd. Caught by the browser check (all API calls
failing), fixed by making the prefix exist in exactly one place.

---

## 4. Reusable units

**Hooks** (`src/hooks/useApi.ts`): `useCompetitions`, `useTeams`, `useSeasons`,
`useMatches`, `usePredictionsForMatch`, `usePredictionHistory`,
`useRequestPredictions`, `useModelStatus`, `useSyncStatus`, `useHealth`, `useReady`.

**Components:** `AppProviders`, `ScreenState` (loading/empty/error), `MatchCard`,
`MarketCard` + `MarketErrorCard` + `MarketPlaceholderCard`, `ProbabilityBar`.

**Domain:** `MARKET_META`, `MARKET_ORDER`, `marketEntries`,
`selectionForProbabilities`, `deriveDoubleChance`,
`mergePartialPredictionResponse`, `formatMarketOutcome`, `formatProbability`;
`pickDefaultSeason`, `upcomingMatches`, `nameMap`.

**Utilities:** `formatKickoff`, `formatTime`, `formatDate`, `formatRelative`,
`formatScore`, `formatMatchStatus`, `formatSeasonName`, `parseTimestamp`.

**Types:** `src/types/api.ts` — one interface per documented response, with
nullability copied from observed payloads.

---

## 5. Duplicated logic / refactoring candidates

See `ARCHITECTURE.md` §D-10. Summary:

1. `formatProbability` and the percentage inside `ProbabilityBar` both round.
2. `MARKET_ORDER` (domain) and `MARKET_NAMES` (types) must be kept in step by hand.
3. The `isLoading / isError / empty` ladder is repeated per screen; a
   `<QueryBoundary>` would remove it mechanically.

---

## 6. Known bugs, workarounds and debt

Beyond `ARCHITECTURE.md` D-1…D-10:

### B-1 — **No `GET /api/v1/matches/:id` (backend gap)**

`/matches` orders by `kickoff_at` **ascending** and caps at 2000, so requesting
everything returns the **oldest** fixtures (2015–2020). Match 4280 was returned
by `?status=scheduled` but not by `?limit=2000`. The detail screen therefore
resolves a match from the `status=scheduled` set plus the match passed through
navigation params.

**Recommendation:** add `GET /api/v1/matches/:id` (and ideally descending order
or a `from`/`to` date filter). This is the one API gap that forces client-side
compromise.

### B-2 — `/status` collides with Metro's dev-server endpoint

Served as the packager status page in `expo start --web`. The route was renamed
to `/system` (`app/(tabs)/system.tsx`). Harmless in a production build, but the
rename keeps dev and production consistent.

### B-3 — Only three of the five specified tabs exist

Home, Fixtures and System are implemented. **Predictions** and **Performance**
were not built because:

- the spec requires prediction history and model performance metrics, and there
  is no `/api/v1/performance` or evaluation endpoint in the contract;
- `GET /api/v1/predictions` returns stored rows but carries no outcome-accuracy
  data, so a "Performance" screen would have to fabricate it.

This is the deliberate "don't invent data" outcome, not an oversight. It needs an
API decision, not more UI work.

### B-4 — Design system not applied

The approved dark theme (midnight navy / analytics green), Inter typography and
5-tab navigation arrived in the final brief while the implementation was already
complete. The current UI uses Paper's default light MD3 theme with a green
primary. The tokens live in `src/theme/theme.ts`, so restyling is centralised —
but **the visual identity in the brief is not implemented**. This is the largest
outstanding gap against the specification.

---

## 7. Test commands and actual results

```bash
cd mobile
npm test                 # jest           -> 8 suites, 76 tests, all passed
npm run typecheck        # tsc --noEmit   -> 0 errors
npm run doctor           # expo-doctor    -> 20/20 checks passed
```

| Check              | Result                                          |
| ------------------ | ----------------------------------------------- |
| `npx tsc --noEmit` | **0 errors**                                    |
| `npx jest`         | **8 suites passed, 76 tests passed**            |
| `npx expo-doctor`  | **20/20 passed**                                |
| Metro web bundle   | builds; **0 console errors, 0 failed requests** |

---

## 8. Live verification against the running Rails backend

Method: `expo start --web` + headless browser, with Rails (`web`), PostgreSQL,
Redis/Sidekiq and the ML container running.

| Workflow                    | Verified  | Evidence                                                                                            |
| --------------------------- | --------- | --------------------------------------------------------------------------------------------------- |
| App launches                | Yes       | Dashboard renders                                                                                   |
| Fetch competitions/fixtures | Yes       | Season 2025/26, "1 of 381 fixtures still to play", 12 seasons listed                                |
| Match list + filters        | Yes       | Arsenal vs Chelsea, Sat 26 Dec 18:00, competition and season chips                                  |
| Open match details          | Yes       | `/matches/4280`, header, competition, season, status                                                |
| Request predictions         | Yes       | POST executed; Rails then returned 4 stored rows                                                    |
| 1X2                         | Yes       | Home 63.6% / Draw 27.7% / Away 8.8% (model 0.3.0)                                                   |
| Over/Under 2.5              | Yes       | Over 87.1% / Under 12.9% (model 0.4.0)                                                              |
| BTTS                        | Yes       | Yes 62.9% / No 37.1% (model 0.4.0)                                                                  |
| Double Chance               | Yes       | 1X 91.2% / X2 36.4% / 12 72.3%, labelled **Derived**                                                |
| Model status                | Yes       | Versions 0.3.0 / 0.4.0 / 0.5.0 with real counts                                                     |
| Sync status                 | Yes       | Both kinds fresh, "Processed 80", next run 2026-10-31                                               |
| Error states                | Partially | Error/empty rendering is unit-tested; only the 404-as-empty path was exercised against the live API |

**Not verified:** native iOS/Android builds (no simulator available), and the
`503 ML unavailable` path end-to-end (the ML service was up throughout).

---

# Stage 2 — Design system and five-destination navigation

Scope: `mobile/` only. `backend/`, `ml/`, `docs/` and `backend/.env` were not
modified. `.env` verified still Git-ignored; no credential was read or copied.
Nothing committed or pushed.

## Files created

```
src/theme/tokens.ts                  palette, spacing, radius, typography
src/theme/paperFonts.ts              Inter mapped onto Paper's variants
src/theme/fonts.ts                   the four Inter weights actually used
src/theme/useAppTheme.ts             typed theme accessor (single cast site)
src/components/StatCard.tsx          metric card
src/components/SectionHeader.tsx     section heading + action
src/hooks/usePredictionOverview.ts   grouping/distribution (pure, tested)
app/(tabs)/predictions/index.tsx     Predictions
app/(tabs)/performance/index.tsx     Performance (activity-only)
app/(tabs)/settings/index.tsx        Settings
app/(tabs)/settings/_layout.tsx      nested Stack for /settings/system
__tests__/theme/theme.test.ts        25 design-system assertions
__tests__/domain/predictionOverview.test.ts
```

## Files modified

```
src/theme/theme.ts                   rewritten: MD3 dark built from tokens
src/components/AppProviders.tsx      font loading, splash, themed fallback
src/components/MatchCard.tsx         tokens; Chip → Text (nested-button fix)
app/(tabs)/_layout.tsx               five tabs, themed
app/(tabs)/index.tsx                 tokens (background, card borders)
app/(tabs)/fixtures/index.tsx        tokens; themed chips
app/(tabs)/system.tsx → app/(tabs)/settings/system.tsx   moved, de-hexed
jest.config.js                       expo-font / expo-asset in transform allowlist
jest.setup.ts                        expo-font + expo-splash-screen stubs
```

## Dependencies added

`@expo-google-fonts/inter`, `expo-asset`. `expo-asset` was **required**, not
optional: `expo-font` imports it, and without it the app could not load fonts at
all (the test failure surfaced the same missing module the runtime would hit).

## Design system

Palette `#101B2D` background, `#202C40` surface, `#16A36A` primary, `#F4F7FB`
text — exactly the approved tokens. Inter 400/500/600/700 only. Elevation flattened
to `transparent` so MD3 does not tint surfaces away from the palette.

**Enforced, not documented:** `__tests__/theme/theme.test.ts` fails if any of 12
screen/component files contains a raw hex literal.

## Verification

| Check | Result |
| --- | --- |
| `npx tsc --noEmit` | **0 errors** |
| `npx jest` | **10 suites, 108 tests, all passed** (was 76) |
| `npx expo-doctor` | **20/20 checks passed** |
| Live sweep, 7 routes | **0 console errors, 0 failed requests** |

Live routes verified: `/`, `/fixtures`, `/predictions`, `/performance`,
`/settings`, `/settings/system`, `/matches/4280` — all with real backend data.

## Outstanding API limitations (unchanged by this stage)

1. **No `GET /api/v1/matches/:id`** — detail still resolves from
   `?status=scheduled` plus navigation params. A deep link to an *old completed*
   match shows "not found". **Backend change required.**
2. **No performance/evaluation endpoint.** Accuracy, Brier, log loss, calibration
   and profitability do not exist anywhere in the API. Performance shows activity
   only and says so. **Backend/ML work required.**
3. **Count semantics differ between endpoints.** `/model_status.prediction_count`
   includes superseded rows (24); `/predictions` returns current rows (4). Both
   are labelled distinctly in the UI.
4. **`/matches` orders ascending and caps at 2000**, so the archive's newest
   fixtures are unreachable without a filter.

## Known defects / debt remaining

- **D-11** Paper `Chip` defaults to an off-palette container; every chip must set
  `style` and `textStyle`. Applied on three screens; caught visually (the chips
  rendered mauve), not by any test.
- **D-12** `StyleSheet.create` cannot read the theme, so colour sits in inline
  style arrays. A `makeStyles(theme)` factory is the natural next step.
- Preferences in Settings are a labelled placeholder, not implemented.

## Not verified

Native iOS/Android builds (no simulator available). All live verification was
Expo **web** against the real Rails + ML stack; native CORS is not a constraint
but native layout/typography was not exercised on a device.
