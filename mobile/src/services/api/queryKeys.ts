/**
 * TanStack Query keys, in one place.
 *
 * Keys are hierarchical (`['matches', filters]`) so that invalidating
 * `['matches']` after a prediction refresh reaches every variant. Inline key
 * arrays are the usual cause of "the screen did not update after a mutation",
 * because two call sites build subtly different arrays.
 */
import type {
  MatchFilters,
  PredictionFilters,
  SeasonFilters,
} from "@/services/api/endpoints";

export const queryKeys = {
  health: () => ["health"] as const,
  ready: () => ["ready"] as const,
  competitions: () => ["competitions"] as const,
  teams: () => ["teams"] as const,
  seasons: (filters: SeasonFilters = {}) => ["seasons", filters] as const,
  matches: (filters: MatchFilters = {}) => ["matches", filters] as const,
  match: (matchId: number) => ["matches", "detail", matchId] as const,
  predictions: (filters: PredictionFilters = {}) =>
    ["predictions", filters] as const,
  predictionsForMatch: (matchId: number) =>
    ["predictions", "match", matchId] as const,
  modelStatus: () => ["modelStatus"] as const,
  syncStatus: () => ["syncStatus"] as const,
} as const;
