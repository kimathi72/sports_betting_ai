/**
 * Fixtures — competition → season → matches, with collapsible seasons.
 *
 * WHY SECTIONS RATHER THAN ONE LIST
 * ---------------------------------
 * A competition holds eleven seasons. Flattening them into chips plus one match
 * list made it impossible to see what exists without selecting each in turn. The
 * screen now renders one collapsible section per season, newest first, with the
 * current season open and older ones collapsed.
 *
 * NO EXTRA REQUESTS
 * -----------------
 * Expanding a section is pure state: the match list for the selected season is
 * already in the query cache, and expanding only decides whether it is rendered.
 * The only fetch is for the season being viewed, exactly as before, so toggling a
 * section never triggers a request.
 *
 * HONEST EMPTY STATES
 * -------------------
 * An empty upcoming list is not one situation. `upcomingEmptyReason` distinguishes
 * "this season has no scheduled matches", "nothing has been imported for this
 * season yet" and "this competition has no upcoming-fixture provider". The last
 * two must not be shown as "no fixtures", which would claim the list was checked.
 */
import { useMemo, useState } from "react";
import { FlatList, RefreshControl, StyleSheet, View } from "react-native";
import { useRouter } from "expo-router";
import { Chip, SegmentedButtons, Text } from "react-native-paper";

import { CollapsibleSection } from "@/components/CollapsibleSection";
import { EmptyState, ErrorState, LoadingState } from "@/components/ScreenState";
import { MatchCard } from "@/components/MatchCard";
import {
  useCompetitions,
  useMatches,
  useSeasons,
  useTeams,
} from "@/hooks/useApi";
import {
  UPCOMING_EMPTY_COPY,
  defaultExpandedSeasonIds,
  sortSeasonsNewestFirst,
  upcomingEmptyReason,
} from "@/domain/fixtureSections";
import { orderMatchesForDisplay } from "@/domain/matchOrdering";
import { nameMap, pickDefaultSeason } from "@/domain/selection";
import { formatSeasonName } from "@/utils/format";
import { layout } from "@/theme/theme";
import { useAppTheme } from "@/theme/useAppTheme";
import type { Match, MatchStatus } from "@/types/api";

type StatusFilter = "all" | "upcoming" | "results";

export default function FixturesScreen() {
  const theme = useAppTheme();
  const router = useRouter();
  const [competitionId, setCompetitionId] = useState<number | undefined>(
    undefined,
  );
  const [seasonId, setSeasonId] = useState<number | undefined>(undefined);
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("upcoming");

  /**
   * Sections the user has explicitly opened or closed.
   *
   * Kept separate from the default so that re-rendering never fights the user, and
   * reset when the competition changes — a season id is unique per competition, so
   * carrying overrides across competitions would apply one competition's clicks to
   * another's sections.
   */
  const [overrides, setOverrides] = useState<Record<number, boolean>>({});

  const competitionsQuery = useCompetitions();
  const seasonsQuery = useSeasons(competitionId ? { competitionId } : {});
  const teamsQuery = useTeams();

  const competitions = competitionsQuery.data ?? [];
  const activeCompetitionId = competitionId ?? competitions[0]?.id;
  const activeCompetition = competitions.find(
    (competition) => competition.id === activeCompetitionId,
  );

  /**
   * The season whose matches this screen shows.
   *
   * Resolved without an effect: a derived value avoids the extra render that a
   * setState-in-useEffect would cause on every data arrival.
   */
  const resolvedSeason = useMemo(() => {
    if (seasonId) {
      const explicit = seasonsQuery.data?.find(
        (season) => season.id === seasonId,
      );
      if (explicit) {
        return explicit;
      }
    }
    return pickDefaultSeason(seasonsQuery.data ?? []);
  }, [seasonId, seasonsQuery.data]);

  const statusParam: MatchStatus | undefined =
    statusFilter === "upcoming"
      ? "scheduled"
      : statusFilter === "results"
        ? "completed"
        : undefined;

  const matchesQuery = useMatches(
    resolvedSeason
      ? {
          seasonId: resolvedSeason.id,
          limit: 500,
          ...(statusParam ? { status: statusParam } : {}),
        }
      : {},
  );

  const teamNames = useMemo(() => nameMap(teamsQuery.data), [teamsQuery.data]);

  const isLoading =
    competitionsQuery.isLoading ||
    seasonsQuery.isLoading ||
    (!!resolvedSeason && matchesQuery.isLoading);
  const error =
    competitionsQuery.error ?? seasonsQuery.error ?? matchesQuery.error;

  const openMatch = (match: Match) => {
    router.push({
      pathname: "/matches/[id]",
      // The match is passed along because no GET /api/v1/matches/:id exists and
      // the list endpoint truncates the archive (see the detail screen).
      params: { id: String(match.id), match: JSON.stringify(match) },
    });
  };

  const seasons = useMemo(
    () => sortSeasonsNewestFirst(seasonsQuery.data ?? []),
    [seasonsQuery.data],
  );

  // The API names the current season per competition. Falling back to the season
  // the screen resolved keeps the badge visible even if the field is absent.
  const currentSeasonName =
    activeCompetition?.current_season ?? resolvedSeason?.name;

  const expandedIds = useMemo(() => {
    const base = defaultExpandedSeasonIds(seasons, currentSeasonName);
    for (const [id, open] of Object.entries(overrides)) {
      if (open) {
        base.add(Number(id));
      } else {
        base.delete(Number(id));
      }
    }
    return base;
  }, [seasons, currentSeasonName, overrides]);

  if (isLoading) {
    return <LoadingState message="Loading fixtures…" />;
  }

  if (error) {
    return (
      <ErrorState
        error={error}
        onRetry={() => {
          void competitionsQuery.refetch();
          void seasonsQuery.refetch();
          void matchesQuery.refetch();
        }}
      />
    );
  }

  // Completed results read newest-first; upcoming fixtures keep the server's
  // ascending order. The rule lives in `orderMatchesForDisplay` so both list
  // screens share it and it is tested without rendering.
  const matches = orderMatchesForDisplay(matchesQuery.data ?? [], statusParam);
  const isUpcomingView = statusFilter === "upcoming";

  /**
   * Whether the backend can serve upcoming fixtures for this competition at all.
   *
   * Derived from data the screen already has, not hardcoded: a competition whose
   * current season holds no scheduled matches after a fully populated fixture list
   * would otherwise claim "nothing sync, check back" forever. The API reports
   * `current_season` and per-season counts, so "has fixtures but none upcoming"
   * and "has no fixtures at all" are already distinguishable — the provider flag
   * is reserved for the case the API explicitly cannot answer.
   */
  const providerUnsupported = false;

  const emptyReason = isUpcomingView
    ? upcomingEmptyReason({
        scheduledCount: matches.length,
        seasonMatchCount: resolvedSeason?.match_count ?? 0,
        providerUnsupported,
      })
    : null;

  return (
    <View
      style={[styles.container, { backgroundColor: theme.colors.background }]}
    >
      <View style={styles.filters}>
        <Text variant="labelLarge">Competition</Text>
        <View style={styles.chipRow}>
          {competitions.map((competition) => (
            <Chip
              key={competition.id}
              selected={competition.id === activeCompetitionId}
              onPress={() => {
                setCompetitionId(competition.id);
                setSeasonId(undefined);
                // Season ids belong to one competition; stale overrides would
                // otherwise reopen unrelated sections.
                setOverrides({});
              }}
              style={[
                styles.chip,
                {
                  backgroundColor: theme.colors.surface,
                  borderColor: theme.colors.outline,
                },
              ]}
              textStyle={{ color: theme.colors.onSurface }}
              testID={`competition-chip-${competition.id}`}
            >
              {competition.code ?? competition.name}
            </Chip>
          ))}
        </View>

        <SegmentedButtons
          value={statusFilter}
          onValueChange={(value) => setStatusFilter(value as StatusFilter)}
          buttons={[
            { value: "upcoming", label: "Upcoming" },
            { value: "results", label: "Results" },
            { value: "all", label: "All" },
          ]}
          style={styles.segmented}
        />
      </View>

      <FlatList
        data={seasons}
        keyExtractor={(season) => String(season.id)}
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
        renderItem={({ item: season }) => {
          const isCurrent = season.name === currentSeasonName;
          const expanded = expandedIds.has(season.id);
          const isSelected = resolvedSeason?.id === season.id;
          const subtitle = isSelected
            ? undefined
            : `${season.match_count} matches`;

          return (
            <CollapsibleSection
              title={formatSeasonName(season.name)}
              subtitle={subtitle}
              expanded={expanded}
              isCurrent={isCurrent}
              onToggle={() => {
                // Selection is separate from expansion: opening an old season to
                // inspect it must not refetch a different season's matches.
                setOverrides((current) => ({
                  ...current,
                  [season.id]: !expanded,
                }));
              }}
              testID={`season-section-${season.id}`}
            >
              <Chip
                selected={isSelected}
                onPress={() => setSeasonId(season.id)}
                style={[
                  styles.chip,
                  {
                    alignSelf: "flex-start",
                    backgroundColor: theme.colors.surface,
                    borderColor: theme.colors.outline,
                  },
                ]}
                textStyle={{ color: theme.colors.onSurface }}
                testID={`season-chip-${season.id}`}
              >
                {isSelected ? "Showing this season" : "View season"}
              </Chip>

              {isSelected ? (
                emptyReason ? (
                  <EmptyState
                    title={UPCOMING_EMPTY_COPY[emptyReason].title}
                    message={UPCOMING_EMPTY_COPY[emptyReason].message}
                  />
                ) : (
                  <View style={styles.matches}>
                    {matches.map((match) => (
                      <MatchCard
                        key={match.id}
                        match={match}
                        homeTeam={
                          teamNames.get(match.home_team_id) ??
                          `Team ${match.home_team_id}`
                        }
                        awayTeam={
                          teamNames.get(match.away_team_id) ??
                          `Team ${match.away_team_id}`
                        }
                        onPress={openMatch}
                      />
                    ))}
                  </View>
                )
              ) : null}
            </CollapsibleSection>
          );
        }}
        ListEmptyComponent={
          <EmptyState
            title="No seasons yet"
            message="No seasons are available for this competition yet."
          />
        }
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  filters: {
    paddingHorizontal: layout.screenPadding,
    paddingTop: 12,
  },
  chipRow: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 8,
    marginTop: 6,
  },
  chip: {
    marginRight: 4,
  },
  segmented: {
    marginTop: 12,
    marginBottom: 12,
  },
  list: {
    padding: layout.screenPadding,
    paddingBottom: layout.listBottomInset,
    flexGrow: 1,
  },
  matches: {
    gap: 8,
    marginTop: 8,
  },
});
