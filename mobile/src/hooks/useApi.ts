/**
 * Feature hooks — the only place a screen gets server data from.
 *
 * Screens never call Axios directly: keeping requests here means the query keys,
 * the cache policy and the 404-as-empty-state rule are defined once.
 */
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { queryKeys } from "@/services/api/queryKeys";
import { getJson, postJson } from "@/services/api/client";
import { endpoints } from "@/services/api/endpoints";
import type {
  MatchFilters,
  PredictionFilters,
  SeasonFilters,
} from "@/services/api/endpoints";
import type {
  Competition,
  HealthResponse,
  Match,
  ModelStatusResponse,
  PredictRequest,
  PredictResponse,
  ReadyResponse,
  Season,
  StoredPredictionsResponse,
  StoredPrediction,
  SyncStatusResponse,
  Team,
} from "@/types/api";
import {
  mergePartialPredictionResponse,
  type MergedPredictions,
} from "@/domain/predictions";
import { ApiError } from "@/services/api/errors";

/** Data that changes once a day at most. */
const STABLE_STALE_TIME = 10 * 60 * 1000;

// Checks the status structurally rather than with `instanceof`.
//
// `instanceof` is unreliable here: an ApiError can cross a module/bundle
// boundary (or be replaced by a test double) and still carry the right status.
// The contract we actually care about is "the backend said 404", so read it.
function isNotFound(error: unknown): boolean {
  return (
    (error instanceof ApiError && error.status === 404) ||
    (typeof error === 'object' &&
      error !== null &&
      'status' in error &&
      (error as { status?: unknown }).status === 404)
  );
}

export function useCompetitions() {
  return useQuery({
    queryKey: queryKeys.competitions(),
    queryFn: () => getJson<Competition[]>(endpoints.competitions()),
    staleTime: STABLE_STALE_TIME,
  });
}

export function useTeams() {
  return useQuery({
    queryKey: queryKeys.teams(),
    queryFn: () => getJson<Team[]>(endpoints.teams()),
    staleTime: STABLE_STALE_TIME,
  });
}

export function useSeasons(filters: SeasonFilters = {}) {
  return useQuery({
    queryKey: queryKeys.seasons(filters),
    queryFn: () => getJson<Season[]>(endpoints.seasons(filters)),
    staleTime: STABLE_STALE_TIME,
  });
}

export function useMatches(filters: MatchFilters = {}, options: { enabled?: boolean } = {}) {
  return useQuery({
    queryKey: queryKeys.matches(filters),
    queryFn: () => getJson<Match[]>(endpoints.matches(filters)),
    enabled: options.enabled ?? true,
    // Fixtures and results are refreshed daily by the backend sync, not
    // continuously; a short window avoids refetching on every screen focus.
    staleTime: 60 * 1000,
  });
}

/**
 * Stored predictions for one match.
 *
 * The backend answers 404 both for an unknown match and for a match that has no
 * prediction yet. That is an empty state, not a failure, so it resolves to an
 * empty result instead of surfacing an error banner.
 */
export function usePredictionsForMatch(matchId: number) {
  return useQuery({
    queryKey: queryKeys.predictionsForMatch(matchId),
    queryFn: async (): Promise<MergedPredictions> => {
      try {
        const data = await getJson<StoredPredictionsResponse>(
          endpoints.predictionsForMatch(matchId),
        );
        return mergePartialPredictionResponse({
          match_id: data.match_id,
          predictions: data.predictions,
          errors: {},
        });
      } catch (error) {
        if (isNotFound(error)) {
          return { byMarket: {}, predictions: [], errors: {}, partial: false };
        }
        throw error;
      }
    },
    enabled: Number.isInteger(matchId) && matchId > 0,
  });
}

export function usePredictionHistory(filters: PredictionFilters = {}) {
  return useQuery({
    queryKey: queryKeys.predictions(filters),
    queryFn: () => getJson<StoredPrediction[]>(endpoints.predictions(filters)),
  });
}

/**
 * Requests predictions.
 *
 * A 207 partial response arrives as a normal `data` payload (Axios does not
 * reject on 2xx), and is merged into the same shape as a 201, so the screen
 * renders the markets that succeeded and shows the failures separately.
 */
export function useRequestPredictions() {
  const queryClient = useQueryClient();

  return useMutation<MergedPredictions, unknown, PredictRequest>({
    mutationFn: async (request) => {
      const response = await postJson<PredictResponse>(
        endpoints.predictions(),
        request,
      );
      return mergePartialPredictionResponse(response);
    },
    onSuccess: (_data, request) => {
      void queryClient.invalidateQueries({
        queryKey: queryKeys.predictionsForMatch(request.match_id),
      });
      void queryClient.invalidateQueries({ queryKey: ["predictions"] });
      void queryClient.invalidateQueries({ queryKey: queryKeys.modelStatus() });
    },
  });
}

export function useModelStatus() {
  return useQuery({
    queryKey: queryKeys.modelStatus(),
    queryFn: () => getJson<ModelStatusResponse>(endpoints.modelStatus()),
    staleTime: 60 * 1000,
  });
}

export function useSyncStatus() {
  return useQuery({
    queryKey: queryKeys.syncStatus(),
    queryFn: () => getJson<SyncStatusResponse>(endpoints.syncStatus()),
    staleTime: 60 * 1000,
  });
}

export function useHealth() {
  return useQuery({
    queryKey: queryKeys.health(),
    queryFn: () => getJson<HealthResponse>(endpoints.health()),
    staleTime: 30 * 1000,
    retry: false,
  });
}

export function useReady() {
  return useQuery({
    queryKey: queryKeys.ready(),
    queryFn: () => getJson<ReadyResponse>(endpoints.ready()),
    staleTime: 30 * 1000,
    retry: false,
  });
}
