/**
 * Response types for the Rails API.
 *
 * Derived from docs/api-contracts.md, which was verified against the running
 * backend. Field names and nullability are copied from observed responses — do
 * not "tidy" them here, because the client and the server must agree exactly.
 */

/** A match status. Closed set, enforced by a database check constraint. */
export type MatchStatus =
  | "scheduled"
  | "postponed"
  | "cancelled"
  | "in_progress"
  | "completed";

export const MATCH_STATUSES: readonly MatchStatus[] = [
  "scheduled",
  "postponed",
  "cancelled",
  "in_progress",
  "completed",
];

/** `GET /api/v1/competitions` — bare array, ordered by name then id. */
export interface Competition {
  id: number;
  name: string;
  code: string | null;
  country: string | null;
  /**
   * One of `europe`, `south_america`, `africa`, `asia`, `north_america`,
   * `other`. Supplied by the backend from the competition catalogue, so the
   * region filter groups by the same values the import side uses instead of the
   * client maintaining its own country list.
   */
  region: string;
  /** Season labels that actually have fixtures, ascending (e.g. `["2023/24", …]`). */
  seasons: string[];
  /** The latest label in `seasons`, or null when the competition has no fixtures. */
  current_season: string | null;
  match_count: number;
  completed_count: number;
}

/** `GET /api/v1/teams` — bare array, ordered by name then id. */
export interface Team {
  id: number;
  name: string;
  country: string | null;
}

/** `GET /api/v1/seasons` — includes per-season match counts. */
export interface Season {
  id: number;
  name: string;
  competition_id: number;
  match_count: number;
  completed_match_count: number;
}

/**
 * `GET /api/v1/matches` — ids only, no nested names. Scores are both present or
 * both null; `kickoff_at` is never null.
 */
export interface Match {
  id: number;
  competition_id: number;
  season_id: number;
  home_team_id: number;
  away_team_id: number;
  kickoff_at: string;
  status: MatchStatus;
  home_score: number | null;
  away_score: number | null;
}

/** The four markets the platform predicts. Double chance is derived. */
export type MarketName = "1x2" | "over_under_2.5" | "btts" | "double_chance";

export const MARKET_NAMES: readonly MarketName[] = [
  "1x2",
  "over_under_2.5",
  "btts",
  "double_chance",
];

/** Canonical outcome key per market (e.g. `H` for 1x2, `over` for O/U 2.5). */
export type OutcomeKey = string;

/** A probability distribution keyed by canonical outcome. */
export type Probabilities = Record<string, number>;

/** One market's prediction, as returned by `POST` and `GET .../:matchId`. */
export interface MarketPrediction {
  market: MarketName;
  selection: string;
  probabilities: Probabilities;
  model_version: string;
  generated_at: string;
  /**
   * Present only on a double-chance prediction computed on the device from the
   * 1X2 distribution. Lets the UI label it honestly instead of implying the
   * backend produced a double-chance model.
   */
  derived?: boolean;
}

/** Body of `POST /api/v1/predictions`. match_id goes in the BODY, not the URL. */
export interface PredictRequest {
  match_id: number;
  markets: MarketName[];
}

/**
 * `POST /api/v1/predictions` response (201 and 207 share this shape).
 * `errors` is keyed by market and empty on full success.
 */
export interface PredictResponse {
  match_id: number;
  predictions: MarketPrediction[];
  errors: Record<string, string>;
}

/** `GET /api/v1/predictions/:id` — `:id` is the match id. */
export interface StoredPredictionsResponse {
  match_id: number;
  predictions: MarketPrediction[];
}

/**
 * An entry in `GET /api/v1/predictions` (the collection).
 *
 * `home_probability` / `draw_probability` / `away_probability` and
 * `most_likely_outcome` are LEGACY 1X2-ONLY fields. For any other market they
 * carry meaningless values (a double-chance row reports away_probability: 1.0).
 * Screens must read `probabilities` and `selection` instead.
 */
export interface StoredPrediction {
  id: number;
  match_id: number;
  market: MarketName;
  model_version: string;
  home_probability: number;
  draw_probability: number;
  away_probability: number;
  probabilities: Probabilities;
  selection: string;
  most_likely_outcome: string;
  generated_at: string;
}

/** `GET /api/v1/health`. */
export interface HealthResponse {
  status: string;
}

/** `GET /api/v1/ready` — 200 ready, 503 not_ready. */
export interface ReadyResponse {
  status: "ready" | "not_ready";
  checks: { database: string };
}

/** `GET /api/v1/model_status`. */
export interface ModelStatusResponse {
  prediction_count: number;
  latest_generated_at: string | null;
  model_versions: ModelVersionStatus[];
}

export interface ModelVersionStatus {
  model_version: string;
  prediction_count: number;
  first_generated_at: string | null;
  latest_generated_at: string | null;
}

/** `GET /api/v1/sync/status` — last fixture/result synchronization. */
export interface SyncStatusResponse {
  status: "ok" | "degraded";
  checked_at: string;
  schedules: {
    fixtures: SyncSchedule;
    results: SyncSchedule;
  };
}

export interface SyncSchedule {
  last_success_at: string | null;
  last_attempt_at: string | null;
  last_attempt: SyncAttempt | null;
  running: boolean;
  stale: boolean;
  stale_after_hours: number;
  schedule: SyncScheduleConfig | null;
}

export interface SyncAttempt {
  status: "running" | "succeeded" | "failed";
  trigger: "schedule" | "manual";
  duration_seconds: number | null;
  counts: SyncCounts;
  error: string | null;
}

export interface SyncCounts {
  fetched: number;
  created: number;
  updated: number;
  skipped: number;
  rejected: number;
}

export interface SyncScheduleConfig {
  cron: string;
  timezone: string;
  description: string;
  next_run_at: string | null;
}

/** The error body Rails returns for every failure. */
export interface ApiErrorBody {
  error?: string;
}
