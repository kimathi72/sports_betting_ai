/**
 * Every API path, defined once.
 *
 * Paths are relative to the Axios `baseURL` (which already ends in `/api/v1`),
 * so they always start with `/`. Defining them here — rather than inline in
 * hooks — is what stops the two contract traps from reappearing per screen:
 *
 *   - `predictions()` is the POST collection; a match id must NOT be appended.
 *   - `predictionsForMatch(id)` uses the MATCH id, matching Rails' `:id`.
 */
import type { MarketName, MatchStatus } from "@/types/api";

// Filter values are explicitly `| undefined` because the project enables
// `exactOptionalPropertyTypes`: a caller building filters from optional screen
// state must be able to pass `{ seasonId: maybeId }` without a compile error,
// and `undefined` means "no filter".
export interface MatchFilters {
  competitionId?: number | undefined;
  seasonId?: number | undefined;
  status?: MatchStatus | undefined;
  limit?: number | undefined;
}

export interface SeasonFilters {
  competitionId?: number | undefined;
  withMatches?: boolean | undefined;
}

export interface PredictionFilters {
  matchId?: number | undefined;
  market?: MarketName | undefined;
  modelVersion?: string | undefined;
  includeHistory?: boolean | undefined;
  limit?: number | undefined;
}

/**
 * Builds `?a=1&b=2` from defined values only. Axios would happily serialise
 * `undefined` as the string "undefined", which Rails rejects with a 400.
 */
function query(
  params: Record<string, string | number | boolean | undefined>,
): string {
  const entries = Object.entries(params).filter(
    (entry): entry is [string, string | number | boolean] =>
      entry[1] !== undefined,
  );

  if (entries.length === 0) {
    return "";
  }

  const search = entries
    .map(
      ([key, value]) =>
        `${encodeURIComponent(key)}=${encodeURIComponent(String(value))}`,
    )
    .join("&");

  return `?${search}`;
}

export const endpoints = {
  health: (): string => "/api/v1/health",
  ready: (): string => "/api/v1/ready",
  competitions: (): string => "/api/v1/competitions",
  teams: (): string => "/api/v1/teams",
  seasons: (filters: SeasonFilters = {}): string =>
    `/api/v1/seasons${query({
      competition_id: filters.competitionId,
      with_matches: filters.withMatches,
    })}`,
  matches: (filters: MatchFilters = {}): string =>
    `/api/v1/matches${query({
      competition_id: filters.competitionId,
      season_id: filters.seasonId,
      status: filters.status,
      limit: filters.limit,
    })}`,
  /** The POST collection. Never append a match id to this path. */
  predictions: (filters: PredictionFilters = {}): string =>
    `/api/v1/predictions${query({
      match_id: filters.matchId,
      market: filters.market,
      model_version: filters.modelVersion,
      include_history: filters.includeHistory,
      limit: filters.limit,
    })}`,
  /** Stored predictions for a fixture. The path segment is the MATCH id. */
  predictionsForMatch: (matchId: number): string =>
    `/api/v1/predictions/${matchId}`,
  modelStatus: (): string => "/api/v1/model_status",
  syncStatus: (): string => "/api/v1/sync/status",
} as const;
