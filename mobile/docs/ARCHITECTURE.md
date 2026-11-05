# Mobile architecture decisions and technical debt

This record captures the decisions taken while completing the mobile MVP, the
reasoning behind them, and the debt knowingly accepted. It is written for the
follow-up audit: where a choice looks odd, the reason is here rather than only in
a commit that was never made.

Status: implementation phase complete; awaiting the full-project audit.

---

## 1. Architectural decisions

### AD-1 — Expo Router as the only navigator

Routing is file-based under `app/`. No React Navigation `native-stack` is
configured by hand. `expo-router` supplies its own stack/screen implementation
via `react-native-screens`, so a second navigator would mean two sources of
truth for the same screen tree and duplicated header configuration.

Consequence: `app.json` already listed `expo-router` as a plugin, but the entry
point was still the default single-component `App.tsx`. That mismatch is fixed by
pointing `package.json#main` at `expo-router/entry` (see AD-2).

### AD-2 — Entry point ownership

`package.json#main` is `expo-router/entry`. `App.tsx` and `index.ts` were the
Expo template's defaults and are **not** used by the router build. They are left
in place rather than deleted: deleting files that a reviewer may be diffing
against is a destructive change, and removing them is a one-line cleanup for the
audit. This is recorded as debt D-1.

### AD-3 — Transport isolation: hooks never see Axios

Screens → hooks (`src/hooks`) → transport helpers (`getJson`/`postJson` in
`src/services/api/client.ts`) → Axios. Nothing above the client imports Axios.

This was introduced because the first hook tests mocked `apiClient` while the
hooks called `getJson`, so the tests passed without ever invoking the hook's
request path. Mocking the _helpers_ makes a broken hook fail its test.

### AD-4 — Errors are normalised once, into one type

`normalizeApiError` turns Axios failures into `ApiError` with `kind`
(`timeout` | `network` | `client` | `server` | `unknown`) and a boolean
`isRetryable`. Screens never branch on `AxiosError`.

`isRetryable` drives whether a "Try again" control is offered at all: offering a
retry for a 400 is dishonest, because the same request will fail identically.

### AD-5 — 404 on a prediction read is an empty state, not an error

`GET /api/v1/predictions/:matchId` returns 404 both for an unknown match and for
a match with no prediction. `usePredictionsForMatch` resolves that to
`{ predictions: [] }` so the screen shows "No prediction yet" plus the button to
generate one, instead of a red error banner.

The check is **structural** (`error.status === 404`) rather than
`instanceof ApiError`, because an error can cross a module or bundle boundary and
lose its prototype.

### AD-6 — Double Chance is derived, never modelled

`deriveDoubleChance` computes 1X = H+D, X2 = D+A, 12 = H+A from the stored 1X2
distribution. It is used **only** when the backend did not return a
double-chance row, and **only** when 1X2 is present. A backend-supplied double
chance always wins.

Derived rows are tagged `derived: true` so the UI can say so instead of implying
the platform trained a fourth model.

### AD-7 — The legacy 1X2 fields are never rendered

Non-1X2 rows from `GET /api/v1/predictions` carry `home_probability`,
`draw_probability`, `away_probability` and `most_likely_outcome` filled with
meaningless 1X2-shaped values (a double-chance row reports
`away_probability: 1.0`). Every screen reads `probabilities` and `selection`
instead. `StoredPrediction` keeps the legacy fields typed only so the API shape
is documented in one place; nothing consumes them.

### AD-8 — Reference data is fetched once and joined on the client

`/matches` carries ids only. `useTeams`, `useCompetitions` and `useSeasons` are
cached with a 10-minute `staleTime` and screens build id→name maps with
`useMemo`. Rationale: the backend offers no joined endpoint, and the reference
sets are small and change rarely.

### AD-9 — Single source of truth for paths and query keys

`src/services/api/endpoints.ts` builds every URL (including query strings, and
omitting absent filters so `undefined` never reaches Rails). `queryKeys.ts` owns
every cache key. Screens contain no string paths.

### AD-10 — React Native Paper, not a bespoke design system

Material Design 3 components from `react-native-paper`, wrapped where reuse is
real (see §5). No custom theme beyond a light MD3 theme; dark mode is not
implemented (D-2).

### AD-11 — State split

TanStack Query owns all server state. There is no Redux/Zustand store: the only
client state is screen-local (`useState`), which avoids a second cache that can
disagree with the query cache.

### AD-12 — Async `act` environment

React Native Testing Library auto-detects concurrent React, so `renderHook`
returns a Promise and must be awaited. Every hook test awaits it. This is a real
API change from RNTL 12 and the reason the first hook run failed.

---

## 2. Implementation patterns

- **Typed filters with `| undefined`.** `exactOptionalPropertyTypes` is on, so
  filter interfaces declare `?: number | undefined`. Without it a caller cannot
  pass `{ seasonId: maybeId }`, which is the normal screen case.
- **`enabled` guards.** `usePredictionsForMatch` is disabled for a non-positive
  id, which prevents a request to `/predictions/undefined` during first render.
- **Loading / empty / error are three explicit states**, rendered by one shared
  `ScreenState` component so no screen invents its own spinner copy.
- **Relative time strings are generated by one formatter** (`src/utils/format.ts`),
  never inline in JSX.
- **No `any`.** The one deliberate escape is the `process.env` assignment in the
  environment spec, needed to simulate an unset variable.

---

## 3. Known bugs, workarounds, and technical debt

### D-1 — Default template entry files remain

`App.tsx` and `index.ts` are unused. Kept to avoid a destructive change during
the takeover. Safe to delete once confirmed nothing references them.

### D-2 — No dark mode

`app.json` pins `userInterfaceStyle: "light"` and the theme is light-only. The
MD3 theme object is centralised, so adding `DarkTheme` is a contained change.

### D-3 — No offline cache persistence

TanStack Query's defaults are in-memory, so a cold start with no network shows an
error state. `@tanstack/query-async-storage-persister` would fix it but adds a
dependency; deliberately deferred. The app does handle the runtime offline case
(no response → `kind: 'network'`, retry offered).

### D-4 — Reference data is joined client-side (see AD-8)

If `/matches` grows to the full multi-season archive without a `season_id`
filter, the client would hold thousands of rows. Screens always filter by season,
so this is currently bounded, but a joined or lookup endpoint would be better.

### D-5 — `generated_at` on a derived double chance is "now"

A derived row has no real generation time. It reports the moment of derivation
and `model_version: 'derived'`. Displaying it as a model timestamp would be
wrong, so the UI shows the 1X2 model version next to it.

### D-6 — No pagination UI

The API has no page/offset pagination, only a `limit` cap. The fixtures screen
requests a single bounded list per season. A large season is truncated rather
than paged. Acceptable for the MVP; the backend has no offset contract to build
against.

### D-7 — Prediction requests are user-initiated only

`POST /api/v1/predictions` is never fired automatically on screen mount, because
each call runs model inference. It is always an explicit button press. A
dashboard that auto-predicts would multiply ML load by the number of visitors.

### D-8 — Jest must load an explicit module registry for env tests

`environment.ts` throws on a missing `EXPO_PUBLIC_API_BASE_URL` by design, and
`client.ts` imports it eagerly. The environment spec therefore resets the module
registry per test and assigns `undefined` to the variable rather than `delete`ing
it, because babel-preset-expo restores deleted variables from the original
environment.

### D-9 — `expo-doctor` may report the web-only `@expo/metro-runtime` pairing

Expected and benign: it exists to support `expo start --web`, which is the only
context where CORS matters for this app.

### D-10 — Duplicated logic to consolidate in the audit

- `formatProbability` (`src/domain/predictions.ts`) and the percentage formatting
  inside `ProbabilityBar` are two implementations of the same rounding.
- `MARKET_ORDER` (domain) and `MARKET_NAMES` (types) express the same set; the
  domain copy defines display order, the types copy is the API enum. They must be
  kept in step manually.
- Each screen repeats the same `if (query.isLoading) … if (query.isError) …`
  ladder even though `ScreenState` exists; converting them to a single
  `<QueryBoundary>` wrapper is a mechanical refactor.

---

## 4. Deliberately not done (out of scope)

- Push notifications, favourites, betting odds or stake handling.
- Authentication — the API has none, and inventing a client-side auth layer would
  be dead code.
- Any change to `backend/` or `ml/`. No backend defect required one.

---

# Stage 2 — Design system implementation

Added after the MVP handover. Decisions AD-13…AD-18 supersede the parts of
AD-10 (light MD3 theme) and D-2 (no dark mode) that described the old state.

## AD-13 — Tokens are the only source of colour, spacing and type

`src/theme/tokens.ts` holds every palette value, the 4px spacing scale, radii
and the type scale. `src/theme/theme.ts` maps them onto Material Design 3.

A **mechanised test** (`__tests__/theme/theme.test.ts`) asserts that 12 screen and
component files contain no raw hex literal. This is deliberate: a design system
that relies on review discipline erodes on the first rushed screen. Adding a
colour to a screen now fails the suite.

## AD-14 — `createTheme()` factory, dark-only for now

`createTheme(colors, states)` returns an `AppTheme` = MD3 theme plus the app's own
slots (`app.*`, `spacing`, `radius`, `typography`). Only `darkTheme` is exported;
a light theme is a second token set passed to the same factory, requiring no
component changes. Implementing light was explicitly out of scope.

**Why not spread `MD3DarkTheme`.** Its defaults are generic greys that drift from
the midnight-navy identity, and its elevation overlay lightens surfaces with
white. `elevation.level0` is set to `transparent` so screens keep the palette
colour; depth comes from 1px borders and the surface/background steps.

## AD-15 — `useAppTheme()` instead of casting at every call site

Paper's `useTheme()` is typed `MD3Theme` and does not know about `theme.app`.
Casting in each screen is the kind of assertion that silently breaks when the
theme grows, so it happens in exactly one function.

## AD-16 — Inter, four weights, never a blank first frame

`@expo-google-fonts/inter` supplies 400/500/600/700 — precisely the weights the
type scale uses. `AppProviders` holds the native splash until fonts resolve, and
renders a **themed spinner** (not a white screen) during the wait.

A font failure is non-fatal: `fontError` unblocks rendering and Paper falls back
to the platform font. Nothing hardcodes a family, so the app degrades rather than
bricks. Tests pass `skipFontLoading` and `jest.setup.ts` stubs `expo-font`.

## AD-17 — Five tabs; System Status nested under Settings

Home, Fixtures, Predictions, Performance, Settings. `app/(tabs)/settings/` is a
nested Stack so `/settings/system` is a child route of the Settings **tab**, not a
sixth destination. The verified screen was moved, not rewritten, and reuses
`useSyncStatus` / `useModelStatus` — it is not duplicated in Settings.

## AD-18 — Performance reports activity, never accuracy

The screen shows prediction counts, model versions and per-market distribution,
all from `/model_status` and `/predictions`. It contains a permanent
"Historical evaluation not yet available" panel naming what is missing
(accuracy, hit rate, Brier, log loss, calibration, profitability) and stating
explicitly that volume is not a quality measure.

**Count consistency:** `/model_status.prediction_count` counts all rows including
superseded ones (24), while `/predictions` returns current rows only (4). The two
are labelled distinctly ("All predictions recorded" vs "Current predictions") so
equal-looking totals cannot read as a bug.

## Additional debt discovered in stage 2

- **D-11 — Chip theming.** Paper's `Chip` defaults to a secondary container that
  renders off-palette (mauve) on this theme. Chips must set `style`/`textStyle`
  explicitly. Applied on Predictions, Fixtures and System; any new chip needs the
  same treatment.
- **D-12 — No theme-aware static StyleSheet colour.** `StyleSheet.create` cannot
  read the theme, so colour lives in inline style arrays. Fine at this size; a
  `makeStyles(theme)` factory would be the next step.
- **D-13 — Excluded from the hex guard.** `src/theme/*` legitimately contains hex.
  Only screens and components are checked.
