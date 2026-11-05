/**
 * Match Details must render a COMPLETED match, not just an upcoming one.
 *
 * THE DEFECT
 * ----------
 * The screen resolved the match from `useMatches({ status: 'scheduled' })` and
 * ignored the match object the list screens pass through navigation params. A
 * completed fixture is not in the scheduled set, so `match` was undefined and the
 * screen rendered "Match not found" — an empty-looking screen for a match the user
 * had just tapped. Upcoming matches worked because they ARE in that set.
 *
 * These tests pin the fix: the passed match is the primary source, the query is
 * only a fallback, and a completed match shows its final score and status.
 */
import { render as rtlRender, screen, waitFor } from "@testing-library/react-native";
import { SafeAreaProvider } from "react-native-safe-area-context";

// Relative, not `@/`: the alias maps to `src/`, and the route lives in `app/`.
import MatchDetailScreen from "../../app/matches/[id]";
import type { Match } from "@/types/api";

const mockUseLocalSearchParams = jest.fn();
const mockUseMatches = jest.fn();
const mockUseTeams = jest.fn();
const mockUseCompetitions = jest.fn();
const mockUseSeasons = jest.fn();
const mockUsePredictionsForMatch = jest.fn();
const mockMutateAsync = jest.fn();

jest.mock("expo-router", () => ({
  useLocalSearchParams: () => mockUseLocalSearchParams(),
}));

jest.mock("@/hooks/useApi", () => ({
  useMatches: (...args: unknown[]) => mockUseMatches(...args),
  useTeams: () => mockUseTeams(),
  useCompetitions: () => mockUseCompetitions(),
  useSeasons: () => mockUseSeasons(),
  usePredictionsForMatch: (...args: unknown[]) =>
    mockUsePredictionsForMatch(...args),
  useRequestPredictions: () => ({
    mutateAsync: mockMutateAsync,
    isPending: false,
    data: undefined,
  }),
}));

const completedMatch: Match = {
  id: 39662,
  competition_id: 1,
  season_id: 6,
  home_team_id: 10,
  away_team_id: 20,
  kickoff_at: "2026-11-02T20:00:00Z",
  status: "completed",
  home_score: 0,
  away_score: 1,
};

const upcomingMatch: Match = {
  id: 40510,
  competition_id: 1,
  season_id: 6,
  home_team_id: 10,
  away_team_id: 20,
  kickoff_at: "2026-11-06T20:00:00Z",
  status: "scheduled",
  home_score: null,
  away_score: null,
};

function idleQuery<T>(data: T) {
  return {
    data,
    isLoading: false,
    isRefetching: false,
    error: null,
    refetch: jest.fn(),
  };
}

function arrange({
  match,
  scheduled = [],
  teams = [
    { id: 10, name: "Newcastle United" },
    { id: 20, name: "Everton" },
  ],
  competitions = [{ id: 1, name: "Premier League", code: "E0" }],
  seasons = [{ id: 6, name: "2026/27", competition_id: 1 }],
  predictions = { byMarket: {}, predictions: [], errors: {}, partial: false },
  matchesError = null,
}: {
  match: Match;
  scheduled?: Match[];
  teams?: { id: number; name: string }[];
  competitions?: { id: number; name: string; code: string }[];
  seasons?: { id: number; name: string; competition_id: number }[];
  predictions?: unknown;
  matchesError?: unknown;
}) {
  mockUseLocalSearchParams.mockReturnValue({
    id: String(match.id),
    match: JSON.stringify(match),
  });
  mockUseMatches.mockReturnValue({
    ...idleQuery(scheduled),
    error: matchesError,
  });
  mockUseTeams.mockReturnValue(idleQuery(teams));
  mockUseCompetitions.mockReturnValue(idleQuery(competitions));
  mockUseSeasons.mockReturnValue(idleQuery(seasons));
  mockUsePredictionsForMatch.mockReturnValue(idleQuery(predictions));
}

// Paper's Snackbar reads safe-area insets, which the real app provides at the
// root. Without a provider the screen throws before anything is asserted, so the
// harness supplies one with fixed metrics.
const SAFE_AREA_METRICS = {
  frame: { x: 0, y: 0, width: 390, height: 844 },
  insets: { top: 47, left: 0, right: 0, bottom: 34 },
};

function render(ui: React.ReactElement) {
  return rtlRender(
    <SafeAreaProvider initialMetrics={SAFE_AREA_METRICS}>{ui}</SafeAreaProvider>,
  );
}

beforeEach(() => {
  jest.clearAllMocks();
});

describe("Match Details — completed match", () => {
  it("renders the match instead of an empty screen", async () => {
    arrange({ match: completedMatch });

    await render(<MatchDetailScreen />);

    expect(screen.queryByText("Match not found")).toBeNull();
    expect(screen.getByTestId("match-head-to-head")).toBeTruthy();
  });

  it("shows both team names", async () => {
    arrange({ match: completedMatch });

    await render(<MatchDetailScreen />);

    expect(screen.getByText("Newcastle United")).toBeTruthy();
    expect(screen.getByText("Everton")).toBeTruthy();
  });

  it("shows the final score", async () => {
    arrange({ match: completedMatch });

    await render(<MatchDetailScreen />);

    expect(screen.getByTestId("detail-score")).toHaveTextContent("0 - 1");
  });

  it("shows the competition and season", async () => {
    arrange({ match: completedMatch });

    await render(<MatchDetailScreen />);

    expect(screen.getByText(/Premier League/)).toBeTruthy();
    expect(screen.getByText(/2026\/27/)).toBeTruthy();
  });

  it("shows the match status", async () => {
    arrange({ match: completedMatch });

    await render(<MatchDetailScreen />);

    // The app's own label for `completed` is "Full time" (formatMatchStatus).
    expect(screen.getByText("Full time")).toBeTruthy();
  });

  it("disables Generate Prediction, because the API refuses a completed match", async () => {
    arrange({ match: completedMatch });

    await render(<MatchDetailScreen />);

    const button = screen.getByTestId("generate-predictions");
    expect(
      button.props.accessibilityState?.disabled ?? button.props.disabled,
    ).toBe(true);
  });

  it("does not depend on the scheduled list to find the match", async () => {
    // The scheduled query returns nothing at all — the exact production case.
    arrange({ match: completedMatch, scheduled: [] });

    await render(<MatchDetailScreen />);

    expect(screen.getByTestId("match-head-to-head")).toBeTruthy();
  });
});

describe("Match Details — upcoming match", () => {
  it("still renders from the passed match", async () => {
    arrange({ match: upcomingMatch });

    await render(<MatchDetailScreen />);

    expect(screen.getByTestId("match-head-to-head")).toBeTruthy();
    expect(screen.getByText("Newcastle United")).toBeTruthy();
  });

  it("shows the kickoff instead of a score", async () => {
    arrange({ match: upcomingMatch });

    await render(<MatchDetailScreen />);

    expect(screen.queryByTestId("detail-score")).toBeNull();
  });

  it("keeps Generate Prediction enabled", async () => {
    arrange({ match: upcomingMatch });

    await render(<MatchDetailScreen />);

    const button = screen.getByTestId("generate-predictions");
    expect(
      button.props.accessibilityState?.disabled ?? button.props.disabled,
    ).toBe(false);
  });

  it("falls back to the scheduled query when no match was passed", async () => {
    // A deep link has no navigation params; the query is the only source.
    mockUseLocalSearchParams.mockReturnValue({ id: String(upcomingMatch.id) });
    mockUseMatches.mockReturnValue(idleQuery([upcomingMatch]));
    mockUseTeams.mockReturnValue(
      idleQuery([
        { id: 10, name: "Newcastle United" },
        { id: 20, name: "Everton" },
      ]),
    );
    mockUseCompetitions.mockReturnValue(
      idleQuery([{ id: 1, name: "Premier League", code: "E0" }]),
    );
    mockUseSeasons.mockReturnValue(
      idleQuery([{ id: 6, name: "2026/27", competition_id: 1 }]),
    );
    mockUsePredictionsForMatch.mockReturnValue(
      idleQuery({ byMarket: {}, predictions: [], errors: {}, partial: false }),
    );

    await render(<MatchDetailScreen />);

    await waitFor(() =>
      expect(screen.getByTestId("match-head-to-head")).toBeTruthy(),
    );
  });
});

describe("Match Details — failure states", () => {
  it("reports an invalid id rather than rendering nothing", async () => {
    mockUseLocalSearchParams.mockReturnValue({ id: "abc" });
    mockUseMatches.mockReturnValue(idleQuery([]));
    mockUseTeams.mockReturnValue(idleQuery([]));
    mockUseCompetitions.mockReturnValue(idleQuery([]));
    mockUseSeasons.mockReturnValue(idleQuery([]));
    mockUsePredictionsForMatch.mockReturnValue(
      idleQuery({ byMarket: {}, predictions: [], errors: {}, partial: false }),
    );

    await render(<MatchDetailScreen />);

    expect(screen.getByText("Invalid match")).toBeTruthy();
  });

  it("shows an error state when the fallback query fails and nothing was passed", async () => {
    mockUseLocalSearchParams.mockReturnValue({ id: "40510" });
    mockUseMatches.mockReturnValue({
      ...idleQuery([]),
      error: new Error("network down"),
    });
    mockUseTeams.mockReturnValue(idleQuery([]));
    mockUseCompetitions.mockReturnValue(idleQuery([]));
    mockUseSeasons.mockReturnValue(idleQuery([]));
    mockUsePredictionsForMatch.mockReturnValue(
      idleQuery({ byMarket: {}, predictions: [], errors: {}, partial: false }),
    );

    await render(<MatchDetailScreen />);

    // An API failure must not look like "no such match".
    expect(screen.queryByText("Match not found")).toBeNull();
  });

  it("says the match is unavailable when it is neither passed nor found", async () => {
    mockUseLocalSearchParams.mockReturnValue({ id: "999999" });
    mockUseMatches.mockReturnValue(idleQuery([]));
    mockUseTeams.mockReturnValue(idleQuery([]));
    mockUseCompetitions.mockReturnValue(idleQuery([]));
    mockUseSeasons.mockReturnValue(idleQuery([]));
    mockUsePredictionsForMatch.mockReturnValue(
      idleQuery({ byMarket: {}, predictions: [], errors: {}, partial: false }),
    );

    await render(<MatchDetailScreen />);

    expect(screen.getByText("Match not found")).toBeTruthy();
  });
});
