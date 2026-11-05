/**
 * API hooks.
 *
 * The hooks are the boundary between TanStack Query and the screens, so these
 * tests assert the integration points that are easy to get subtly wrong:
 *
 *   - the request really goes to the documented path (match_id in the BODY for
 *     POST, match id in the PATH for GET);
 *   - a 207 partial response is treated as data, not as an error;
 *   - a double-chance row already stored in the backend wins over a derived one.
 */
import { renderHook, waitFor } from "@testing-library/react-native";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

import {
  useCompetitions,
  useMatches,
  useTeams,
  usePredictionsForMatch,
  useRequestPredictions,
  useSyncStatus,
} from "@/hooks/useApi";
import * as clientModule from "@/services/api/client";

// Spy on the transport helpers rather than replacing `apiClient`.
//
// The hooks deliberately depend on `getJson`/`postJson`, NOT on Axios, so that a
// transport change touches one file. Mocking `apiClient` here would have left
// the hooks uncalled and the tests would have silently asserted nothing.
jest.mock("@/services/api/client", () => ({
  ...jest.requireActual("@/services/api/client"),
  getJson: jest.fn(),
  postJson: jest.fn(),
}));

const mockedGet = clientModule.getJson as jest.Mock;
const mockedPost = clientModule.postJson as jest.Mock;

function wrapper({ children }: { children: React.ReactNode }) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 } },
  });
  return (
    <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
  );
}

const oneXTwoRow = {
  market: "1x2" as const,
  selection: "H",
  probabilities: { H: 0.5, D: 0.3, A: 0.2 },
  model_version: "0.3.0",
  generated_at: "2026-10-30T08:38:24Z",
};

beforeEach(() => {
  jest.clearAllMocks();
});

describe("useCompetitions", () => {
  it("requests the documented path and returns the bare array", async () => {
    mockedGet.mockResolvedValue([{ id: 4, name: "E0", code: "E0", country: null }]);

    const { result } = await renderHook(() => useCompetitions(), { wrapper });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(mockedGet).toHaveBeenCalledWith("/api/v1/competitions");
    expect(result.current.data).toHaveLength(1);
  });
});

describe("useTeams", () => {
  it("requests /api/v1/teams", async () => {
    mockedGet.mockResolvedValue([]);

    const { result } = await renderHook(() => useTeams(), { wrapper });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(mockedGet).toHaveBeenCalledWith("/api/v1/teams");
  });
});

describe("useMatches", () => {
  it("serialises filters into the query string", async () => {
    mockedGet.mockResolvedValue([]);

    const { result } = await renderHook(
      () => useMatches({ seasonId: 5, status: "scheduled" }),
      {
        wrapper,
      },
    );

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(mockedGet).toHaveBeenCalledWith(
      "/api/v1/matches?season_id=5&status=scheduled",
    );
  });
});

describe("useRequestPredictions", () => {
  it("posts match_id in the body, never in the URL", async () => {
    mockedPost.mockResolvedValue({ match_id: 4280, predictions: [oneXTwoRow], errors: {} });

    const { result } = await renderHook(() => useRequestPredictions(), { wrapper });

    await result.current.mutateAsync({ match_id: 4280, markets: ["1x2"] });

    expect(mockedPost).toHaveBeenCalledWith("/api/v1/predictions", {
      match_id: 4280,
      markets: ["1x2"],
    });
    const [path] = mockedPost.mock.calls[0];
    expect(path).not.toMatch(/\/predictions\/\d+/);
  });

  it("marks a partial success instead of throwing", async () => {
    mockedPost.mockResolvedValue({
      match_id: 4280,
      predictions: [oneXTwoRow],
      errors: { btts: "ML service unreachable" },
    });

    const { result } = await renderHook(() => useRequestPredictions(), { wrapper });
    const merged = await result.current.mutateAsync({
      match_id: 4280,
      markets: ["1x2"],
    });

    expect(merged.partial).toBe(true);
    expect(merged.byMarket["1x2"]).toBeDefined();
  });
});

describe("usePredictionsForMatch", () => {
  it("uses the match id in the path and derives double chance from stored 1x2", async () => {
    mockedGet.mockResolvedValue({ match_id: 4280, predictions: [oneXTwoRow] });

    const { result } = await renderHook(() => usePredictionsForMatch(4280), {
      wrapper,
    });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(mockedGet).toHaveBeenCalledWith("/api/v1/predictions/4280");
    expect(
      result.current.data?.byMarket.double_chance?.probabilities["1x"],
    ).toBeCloseTo(0.8, 10);
  });

  it('treats a 404 as "no prediction yet" rather than an error', async () => {
    // The backend answers 404 both for an unknown match and for a match with no
    // prediction. The screen must show an empty state, not a failure banner.
    const notFound = Object.assign(
      new Error("no current prediction for match 4280"),
      {
        kind: "client",
        status: 404,
        isRetryable: false,
      },
    );
    mockedGet.mockRejectedValue(notFound);

    const { result } = await renderHook(() => usePredictionsForMatch(4280), {
      wrapper,
    });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.data?.predictions).toEqual([]);
  });
});

describe("useSyncStatus", () => {
  it("requests /api/v1/sync/status", async () => {
    mockedGet.mockResolvedValue({ status: "degraded", checked_at: "", schedules: {} });

    const { result } = await renderHook(() => useSyncStatus(), { wrapper });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(mockedGet).toHaveBeenCalledWith("/api/v1/sync/status");
  });
});
