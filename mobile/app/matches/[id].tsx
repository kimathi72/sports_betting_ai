/**
 * Match detail — fixture information plus the four prediction markets.
 *
 * Prediction generation is an explicit button press (debt D-7): each request
 * runs model inference, so mounting the screen must not trigger one. Existing
 * predictions are read from the cheap `GET /api/v1/predictions/:matchId`.
 */
import { useMemo, useState } from 'react';
import { ScrollView, StyleSheet, View } from "react-native";
import { useLocalSearchParams } from "expo-router";
import {
  Button,
  Chip,
  Divider,
  Searchbar,
  Snackbar,
  Text,
} from "react-native-paper";

import { EmptyState, ErrorState, LoadingState } from "@/components/ScreenState";
import {
  MarketCard,
  MarketErrorCard,
  MarketPlaceholderCard,
} from "@/components/MarketCard";
import { TeamCrest } from "@/components/TeamCrest";
import {
  useCompetitions,
  useMatches,
  usePredictionsForMatch,
  useRequestPredictions,
  useSeasons,
  useTeams,
} from "@/hooks/useApi";
import { MARKET_ORDER } from "@/domain/predictions";
import { nameMap } from "@/domain/selection";
import { normalizeApiError } from "@/services/api/errors";
import {
  formatKickoff,
  formatMatchStatus,
  formatScore,
  formatSeasonName,
} from "@/utils/format";
import { layout } from "@/theme/theme";
import { palette, radius, spacing } from "@/theme/tokens";
import type { MarketName, Match } from "@/types/api";
import { MARKET_NAMES } from "@/types/api";


/**
 * Reads a match passed through navigation params.
 *
 * Expo Router params are strings, so the object is JSON-encoded by the caller.
 * A malformed or absent value returns null and the screen falls back to the
 * query. Parsing is defensive because a bad param must not crash the screen.
 */
function parseMatchParam(raw: string | string[] | undefined): Match | null {
  if (typeof raw !== 'string' || raw.length === 0) {
    return null;
  }
  try {
    const parsed: unknown = JSON.parse(raw);
    if (
      typeof parsed === 'object' &&
      parsed !== null &&
      'id' in parsed &&
      typeof (parsed as Match).id === 'number' &&
      'kickoff_at' in parsed
    ) {
      return parsed as Match;
    }
  } catch {
    return null;
  }
  return null;
}

export default function MatchDetailScreen() {
  const params = useLocalSearchParams<{ id: string; match?: string }>();
  const matchId = Number(params.id);
  const validId = Number.isInteger(matchId) && matchId > 0;

  const [selectedMarkets, setSelectedMarkets] = useState<MarketName[]>([
    ...MARKET_NAMES,
  ]);
  const [snackbar, setSnackbar] = useState<string | null>(null);

  // There is no GET /api/v1/matches/:id, and /matches?limit=2000 truncates the
  // archive, so a match outside the first page cannot be found by scanning.
  // The list screens therefore pass the match they already have through
  // navigation params, and this is the primary source. The query below is only
  // a fallback for a deep link.
  const passed = useMemo(() => parseMatchParam(params.match), [params.match]);
  // No GET /api/v1/matches/:id exists. Worse, /matches orders by kickoff
  // ASCENDING and caps at 2000 rows, so asking for everything returns the
  // OLDEST fixtures (2015-2020) and a current match is never in the page.
  // Querying the scheduled set instead is small, current, and is where a
  // fixture a user is about to predict actually lives. Completed-looking
  // matches are resolved from the same cache when the user came from a list.
  const upcomingQuery = useMatches({ status: 'scheduled', limit: 2000 });
  const teamsQuery = useTeams();
  const competitionsQuery = useCompetitions();
  const seasonsQuery = useSeasons();
  const predictionsQuery = usePredictionsForMatch(validId ? matchId : 0);
  const requestPredictions = useRequestPredictions();

  // THE PASSED MATCH IS THE PRIMARY SOURCE.
  //
  // This screen used to resolve the match ONLY from the scheduled query, which
  // meant a completed fixture — not in that set — fell through to "Match not
  // found". The list screens already hand over the full match object, so use it
  // first and treat the query as a deep-link fallback. The id is still checked:
  // a stale param must not display a different match than the route names.
  const match = useMemo(() => {
    if (passed && passed.id === matchId) {
      return passed;
    }
    return upcomingQuery.data?.find((candidate) => candidate.id === matchId);
  }, [passed, upcomingQuery.data, matchId]);

  const teamNames = useMemo(() => nameMap(teamsQuery.data), [teamsQuery.data]);
  const competitionNames = useMemo(
    () => nameMap(competitionsQuery.data),
    [competitionsQuery.data],
  );
  const seasonNames = useMemo(
    () => nameMap(seasonsQuery.data),
    [seasonsQuery.data],
  );

  const latestByMarket = requestPredictions.data?.byMarket;
  const storedByMarket = predictionsQuery.data?.byMarket;
  const merged = latestByMarket ?? storedByMarket;
  // Failures only exist on a fresh POST response; a stored read has no errors.
  const marketErrors = requestPredictions.data?.errors ?? {};
  const isPartial = requestPredictions.data?.partial ?? false;

  const toggleMarket = (market: MarketName) => {
    setSelectedMarkets((current) =>
      current.includes(market)
        ? current.filter((item) => item !== market)
        : [...current, market],
    );
  };

  const onGenerate = async () => {
    if (selectedMarkets.length === 0) {
      setSnackbar("Select at least one market.");
      return;
    }
    try {
      const result = await requestPredictions.mutateAsync({
        match_id: matchId,
        markets: MARKET_ORDER.filter((market) =>
          selectedMarkets.includes(market),
        ),
      });
      if (result.partial) {
        setSnackbar(
          "Some markets could not be generated. See the notes below.",
        );
      }
    } catch (error) {
      setSnackbar(normalizeApiError(error).message);
    }
  };

  if (!validId) {
    return (
      <EmptyState
        title="Invalid match"
        message="This match reference is not valid."
      />
    );
  }

  // Only wait for the fallback query when there is no passed match to show.
  if ((!passed && upcomingQuery.isLoading) || teamsQuery.isLoading) {
    return <LoadingState message="Loading match…" />;
  }

  // A failed fallback query is only an error when it was the only source. With a
  // passed match the screen has everything it needs, and an unrelated list
  // failure must not replace a match the user just opened.
  if (!passed && upcomingQuery.error) {
    return (
      <ErrorState
        error={upcomingQuery.error}
        onRetry={() => {
          void upcomingQuery.refetch();
        }}
      />
    );
  }

  if (!match) {
    // A 404 from the backend is also possible; this covers "not in the list we
    // loaded", which is the same user-facing situation.
    return (
      <EmptyState
        title="Match not found"
        message="This fixture is no longer available."
      />
    );
  }

  const homeTeam =
    teamNames.get(match.home_team_id) ?? `Team ${match.home_team_id}`;
  const awayTeam =
    teamNames.get(match.away_team_id) ?? `Team ${match.away_team_id}`;
  const score = formatScore(match.home_score, match.away_score);
  const isCompleted = match.status === "completed";
  const isBusy = requestPredictions.isPending;

  return (
    <ScrollView contentContainerStyle={styles.content}>
      <View style={styles.headToHead} testID="match-head-to-head">
        <Text variant="labelMedium" style={styles.competitionLine}>
          {competitionNames.get(match.competition_id) ?? "Competition"} ·{" "}
          {formatSeasonName(seasonNames.get(match.season_id))}
        </Text>

        <View style={styles.sideRow}>
          {/* Crests at 72px: the mockup's "prominent head-to-head" size. They use the
              same verified source as every list row, so a club looks the same here and
              in the fixture list. */}
          <View style={styles.side}>
            <TeamCrest name={homeTeam} size="matchDetail" />
            <Text variant="titleSmall" style={styles.sideName} numberOfLines={2}>
              {homeTeam}
            </Text>
          </View>

          <View style={styles.centre}>
            {score ? (
              <Text variant="displaySmall" style={styles.score} testID="detail-score">
                {score}
              </Text>
            ) : (
              <Text variant="labelLarge" style={styles.kickoff}>
                {formatKickoff(match.kickoff_at)}
              </Text>
            )}
            <Text variant="labelSmall" style={styles.statusLabel}>
              {formatMatchStatus(match.status)}
            </Text>
          </View>

          <View style={styles.side}>
            <TeamCrest name={awayTeam} size="matchDetail" />
            <Text variant="titleSmall" style={styles.sideName} numberOfLines={2}>
              {awayTeam}
            </Text>
          </View>
        </View>
      </View>

      <Text variant="titleMedium" style={styles.sectionTitle}>
        Predictions
      </Text>

      {predictionsQuery.isLoading && !merged ? (
        <LoadingState message="Loading predictions…" />
      ) : null}

      {merged ? (
        MARKET_ORDER.map((market) => {
          const prediction = merged[market];
          if (prediction) {
            return <MarketCard key={market} prediction={prediction} />;
          }
          const failure = marketErrors[market];
          if (failure) {
            return (
              <MarketErrorCard key={market} market={market} message={failure} />
            );
          }
          return prediction === undefined &&
            selectedMarkets.includes(market) ? (
            <MarketPlaceholderCard key={market} market={market} />
          ) : null;
        })
      ) : (
        <EmptyState
          title="No predictions yet"
          message="Choose the markets you want and generate a prediction."
        />
      )}

      <Divider style={styles.divider} />

      <Text variant="titleSmall" style={styles.sectionTitle}>
        Markets to generate
      </Text>
      <View style={styles.marketRow}>
        {MARKET_ORDER.map((market) => (
          <Chip
            key={market}
            selected={selectedMarkets.includes(market)}
            onPress={() => toggleMarket(market)}
            style={styles.marketChip}
            testID={`select-market-${market}`}
          >
            {market}
          </Chip>
        ))}
      </View>

      <Button
        mode="contained"
        onPress={() => {
          void onGenerate();
        }}
        loading={isBusy}
        disabled={isBusy || isCompleted}
        style={styles.button}
        testID="generate-predictions"
      >
        Generate predictions
      </Button>

      {isCompleted ? (
        <Text variant="bodySmall" style={styles.note}>
          This match has a final result, so the API will refuse a new
          prediction.
        </Text>
      ) : null}

      {isPartial ? (
        <Text variant="bodySmall" style={styles.note} testID="partial-note">
          Partial result: some markets were unavailable.
        </Text>
      ) : null}

      <Snackbar
        visible={snackbar !== null}
        onDismiss={() => setSnackbar(null)}
        duration={6000}
      >
        {snackbar ?? ""}
      </Snackbar>
    </ScrollView>
  );
}

// Imported for the Searchbar type only; the component itself is unused here.
void Searchbar;

const styles = StyleSheet.create({
  content: {
    padding: layout.screenPadding,
    paddingBottom: layout.listBottomInset,
  },
  headToHead: {
    backgroundColor: palette.surface,
    borderRadius: radius.panel,
    borderWidth: 1,
    borderColor: palette.border,
    padding: spacing.standard,
    marginBottom: spacing.standard,
    gap: spacing.medium,
  },
  competitionLine: {
    opacity: 0.75,
    textAlign: "center",
  },
  sideRow: {
    flexDirection: "row",
    alignItems: "flex-start",
  },
  side: {
    flex: 1,
    alignItems: "center",
    gap: spacing.small,
  },
  sideName: {
    textAlign: "center",
    fontWeight: "600",
  },
  centre: {
    minWidth: 84,
    alignItems: "center",
    gap: 2,
    paddingTop: spacing.small,
  },
  score: {
    fontWeight: "700",
  },
  kickoff: {
    textAlign: "center",
  },
  statusLabel: {
    opacity: 0.7,
  },
  sectionTitle: {
    marginBottom: 8,
  },
  divider: {
    marginVertical: 16,
  },
  marketRow: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 8,
    marginBottom: 16,
  },
  marketChip: {
    marginRight: 4,
  },
  button: {
    marginTop: 4,
  },
  note: {
    marginTop: 12,
    opacity: 0.75,
  },
});
