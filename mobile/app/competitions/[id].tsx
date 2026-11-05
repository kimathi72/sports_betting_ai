/**
 * Competition Details — one competition, its seasons and its fixtures.
 *
 * Route: `/competitions/[id]` (a top-level route, outside the tab bar, so opening a
 * competition from the Competitions tab keeps the tab selection underneath it).
 *
 * DATA (all from real endpoints, no preview data):
 *  - the competition: `useCompetitions()`, filtered to the route's id;
 *  - its seasons: `GET /api/v1/seasons?competition_id=…`;
 *  - matches for the selected season: `GET /api/v1/matches?season_id=…`.
 *
 * The season list comes from the API, so a season the backend does not have is not
 * offered and none is invented. The default season is the latest one that has
 * fixtures. The match tabs narrow the same season query rather than issuing a second
 * request per tab.
 */
import { useMemo, useState } from "react";
import { FlatList, RefreshControl, StyleSheet, View } from "react-native";
import { useLocalSearchParams, useRouter } from "expo-router";
import { ActivityIndicator, SegmentedButtons, Text } from "react-native-paper";

import { CompetitionLogo } from "@/components/CompetitionLogo";
import { CountryFlag } from "@/components/CountryFlag";
import { EmptyState, ErrorState, LoadingState } from "@/components/ScreenState";
import { FilterChips } from "@/components/FilterChips";
import type { FilterOption } from "@/components/FilterChips";
import { MatchCard } from "@/components/MatchCard";
import {
  useCompetitions,
  useMatches,
  useSeasons,
  useTeams,
} from "@/hooks/useApi";
import { orderMatchesForDisplay } from "@/domain/matchOrdering";
import { nameMap, pickDefaultSeason } from "@/domain/selection";
import { layout } from "@/theme/theme";
import { spacing } from "@/theme/tokens";
import { useAppTheme } from "@/theme/useAppTheme";
import type { Match, Season } from "@/types/api";

type MatchTab = "all" | "results" | "upcoming";

const MATCH_TABS: readonly FilterOption<MatchTab>[] = [
  { value: "all", label: "All" },
  { value: "results", label: "Results" },
  { value: "upcoming", label: "Upcoming" },
];

export default function CompetitionDetailsScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const competitionId = Number(id);
  const router = useRouter();
  const theme = useAppTheme();

  const competitionsQuery = useCompetitions();
  const seasonsQuery = useSeasons(
    Number.isFinite(competitionId) ? { competitionId } : {},
  );
  const teamsQuery = useTeams();

  const [selectedSeasonId, setSelectedSeasonId] = useState<number | undefined>(
    undefined,
  );
  const [matchTab, setMatchTab] = useState<MatchTab>("all");

  const competition = useMemo(
    () => competitionsQuery.data?.find((entry) => entry.id === competitionId),
    [competitionsQuery.data, competitionId],
  );

  const seasons = seasonsQuery.data ?? [];
  // `pickDefaultSeason` returns `null` when there is no season, which is exactly
  // the "no season available" signal the screen needs — but the declared type must
  // say `null`, not `undefined`, or the value is not assignable under strict mode.
  const season: Season | null = useMemo(() => {
    if (selectedSeasonId) {
      const explicit = seasons.find((entry) => entry.id === selectedSeasonId);
      if (explicit) return explicit;
    }
    return pickDefaultSeason(seasons);
  }, [selectedSeasonId, seasons]);

  const status =
    matchTab === "results"
      ? "completed"
      : matchTab === "upcoming"
        ? "scheduled"
        : undefined;
  const matchesQuery = useMatches(
    season
      ? { seasonId: season.id, limit: 500, ...(status ? { status } : {}) }
      : {},
    { enabled: Boolean(season) },
  );

  const teamNames = useMemo(() => nameMap(teamsQuery.data), [teamsQuery.data]);
  // Same rule as the Fixtures screen: completed results newest-first, upcoming
  // fixtures in the server's ascending order.
  const matches = orderMatchesForDisplay(matchesQuery.data ?? [], status);

  if (competitionsQuery.isLoading || seasonsQuery.isLoading) {
    return <LoadingState message="Loading competition…" />;
  }

  if (competitionsQuery.error) {
    return (
      <ErrorState
        error={competitionsQuery.error}
        onRetry={() => {
          void competitionsQuery.refetch();
        }}
      />
    );
  }

  if (!competition) {
    return (
      <EmptyState
        title="Competition not found"
        message="This competition is not available. It may have been removed or the link is wrong."
      />
    );
  }

  const openMatch = (match: Match) => {
    router.push({
      pathname: "/matches/[id]",
      params: { id: String(match.id), match: JSON.stringify(match) },
    });
  };

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <View style={styles.identity}>
          <CompetitionLogo
            code={competition.code}
            name={competition.name}
            size="header"
          />
          <View style={styles.identityText}>
            <Text
              variant="headlineSmall"
              numberOfLines={2}
              style={styles.title}
            >
              {competition.name}
            </Text>
            <View style={styles.countryRow}>
              <CountryFlag country={competition.country} size="small" />
              <Text variant="bodySmall" style={styles.muted}>
                {competition.country ?? "International"}
              </Text>
            </View>
            {season ? (
              <Text variant="labelSmall" style={styles.muted}>
                {matches.length > 0 ? `${matches.length} shown` : "No fixtures"}{" "}
                · {season.match_count} in season
              </Text>
            ) : null}
          </View>
        </View>
      </View>

      {seasons.length > 0 ? (
        <FilterChips
          options={seasons
            .slice()
            .sort((a, b) => a.name.localeCompare(b.name))
            .map((entry) => ({ value: String(entry.id), label: entry.name }))}
          value={String(season?.id ?? seasons[0]?.id ?? "")}
          onChange={(value) => setSelectedSeasonId(Number(value))}
          testIDPrefix="season"
        />
      ) : (
        <Text variant="bodyMedium" style={styles.noSeasons}>
          No seasons imported for this competition yet.
        </Text>
      )}

      <View style={styles.tabs}>
        <SegmentedButtons
          value={matchTab}
          onValueChange={(value) => setMatchTab(value as MatchTab)}
          buttons={MATCH_TABS.map((option) => ({
            value: option.value,
            label: option.label,
          }))}
        />
      </View>

      {!season ? (
        <EmptyState
          title="No fixtures"
          message="This competition has no imported seasons or matches."
        />
      ) : matchesQuery.error ? (
        <ErrorState
          error={matchesQuery.error}
          onRetry={() => {
            void matchesQuery.refetch();
          }}
        />
      ) : matchesQuery.isLoading ? (
        <View style={styles.loading}>
          <ActivityIndicator color={theme.colors.primary} />
        </View>
      ) : (
        <FlatList
          data={matches}
          keyExtractor={(match) => String(match.id)}
          contentContainerStyle={styles.list}
          refreshControl={
            <RefreshControl
              refreshing={matchesQuery.isRefetching}
              onRefresh={() => {
                void matchesQuery.refetch();
              }}
              tintColor={theme.colors.primary}
            />
          }
          renderItem={({ item }) => (
            <View style={styles.item}>
              <MatchCard
                match={item}
                homeTeam={
                  teamNames.get(item.home_team_id) ??
                  `Team ${item.home_team_id}`
                }
                awayTeam={
                  teamNames.get(item.away_team_id) ??
                  `Team ${item.away_team_id}`
                }
                onPress={openMatch}
              />
            </View>
          )}
          ListEmptyComponent={
            <EmptyState
              title={`No ${matchTab === "all" ? "" : matchTab} matches`}
              message="This season has no matches in the selected tab."
            />
          }
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  header: {
    paddingHorizontal: layout.screenPadding,
    paddingTop: spacing.standard,
  },
  identity: {
    flexDirection: "row",
    alignItems: "center",
    gap: spacing.standard,
  },
  identityText: {
    flex: 1,
    gap: 2,
  },
  title: {
    fontWeight: "700",
  },
  countryRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
  },
  muted: {
    opacity: 0.75,
  },
  noSeasons: {
    paddingHorizontal: layout.screenPadding,
    paddingVertical: spacing.medium,
    opacity: 0.75,
  },
  tabs: {
    paddingHorizontal: layout.screenPadding,
    paddingVertical: spacing.small,
  },
  list: {
    paddingHorizontal: layout.screenPadding,
    paddingBottom: layout.listBottomInset,
    flexGrow: 1,
  },
  item: {
    marginBottom: spacing.medium,
  },
  loading: {
    paddingTop: spacing.section,
    alignItems: "center",
  },
});
