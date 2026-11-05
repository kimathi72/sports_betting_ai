/**
 * Home / Explore — the landing screen.
 *
 * Three blocks, all fed by real requests:
 *
 *  1. The AI Predictions hero. It states what the product does; it shows no number,
 *     because a headline accuracy figure would have to come from a measured
 *     evaluation, not from a design.
 *  2. Activity: live / upcoming / results counts. These come from `match_count`
 *     on the competitions payload and one scheduled-fixtures query — never from
 *     placeholders.
 *  3. Top competitions, with their real crests, flags and fixture counts.
 *
 * The screen deliberately does NOT request predictions: each POST runs model
 * inference, so a dashboard would multiply ML load by every visitor. Predictions are
 * fetched on the match they belong to.
 */
import { useMemo } from "react";
import { Pressable, ScrollView, StyleSheet, View } from "react-native";
import { useRouter } from "expo-router";
import { ActivityIndicator, Text } from "react-native-paper";

import { CompetitionCard } from "@/components/CompetitionCard";
import { MatchCard } from "@/components/MatchCard";
import { EmptyState, ErrorState, LoadingState } from "@/components/ScreenState";
import {
  useCompetitions,
  useMatches,
  useSeasons,
  useTeams,
} from "@/hooks/useApi";
import { nameMap, pickDefaultSeason, upcomingMatches } from "@/domain/selection";
import { layout } from "@/theme/theme";
import { palette, radius, spacing } from "@/theme/tokens";
import { useAppTheme } from "@/theme/useAppTheme";
import type { Competition, Match } from "@/types/api";

const FIXTURE_LIMIT = 5;
const COMPETITION_LIMIT = 5;

export function activitySummary(
  competitions: readonly Competition[],
  scheduledCount: number
): { results: number; upcoming: number; total: number } {
  const results = competitions.reduce((sum, competition) => sum + competition.completed_count, 0);
  const total = competitions.reduce((sum, competition) => sum + competition.match_count, 0);
  return { results, upcoming: scheduledCount, total };
}

export default function HomeScreen() {
  const theme = useAppTheme();
  const router = useRouter();

  const competitionsQuery = useCompetitions();
  const seasonsQuery = useSeasons();
  const teamsQuery = useTeams();

  const competitions = useMemo(() => competitionsQuery.data ?? [], [competitionsQuery.data]);

  // The app's "current" season is the latest one that has fixtures. Asking the API
  // for it by name would need a second lookup; picking from the seasons list keeps
  // this to one request and cannot select a season the backend does not have.
  const season = useMemo(
    () => pickDefaultSeason(seasonsQuery.data ?? []),
    [seasonsQuery.data]
  );

  const upcomingQuery = useMatches(
    season ? { seasonId: season.id, limit: 100, status: "scheduled" } : {},
    { enabled: Boolean(season) }
  );

  const teamNames = useMemo(() => nameMap(teamsQuery.data), [teamsQuery.data]);
  const upcoming = useMemo(() => upcomingMatches(upcomingQuery.data ?? [], FIXTURE_LIMIT), [
    upcomingQuery.data,
  ]);

  // Most fixtures first: the competitions a user is most likely to open are the
  // ones the backend has actually backfilled.
  const topCompetitions = useMemo(
    () =>
      [...competitions]
        .sort((a, b) => b.match_count - a.match_count || a.name.localeCompare(b.name))
        .slice(0, COMPETITION_LIMIT),
    [competitions]
  );

  const activity = activitySummary(competitions, upcomingQuery.data?.length ?? 0);

  if (competitionsQuery.isLoading || seasonsQuery.isLoading) {
    return <LoadingState message="Loading football data…" />;
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

  const openCompetition = (competition: Competition) => {
    router.push({ pathname: "/competitions/[id]", params: { id: String(competition.id) } });
  };

  const openMatch = (match: Match) => {
    router.push({
      pathname: "/matches/[id]",
      params: { id: String(match.id), match: JSON.stringify(match) },
    });
  };

  return (
    <ScrollView
      style={{ backgroundColor: theme.colors.background }}
      contentContainerStyle={styles.content}
      testID="home-scroll"
    >
      <View style={styles.header}>
        <Text variant="headlineSmall" style={styles.title}>
          Explore
        </Text>
        <Text variant="bodySmall" style={styles.subtitle}>
          Football analytics across {competitions.length} competitions
        </Text>
      </View>

      {/* Hero. No invented stat: the copy states capability, not a measured score. */}
      <View style={styles.hero} testID="ai-hero">
        <View style={styles.heroGlow} />
        <Text variant="titleMedium" style={styles.heroTitle}>
          AI Predictions
        </Text>
        <Text variant="bodySmall" style={styles.heroSubtitle}>
          Powered by advanced machine learning
        </Text>
        <View style={styles.heroRow}>
          <Text variant="labelSmall" style={styles.heroMeta}>
            1X2 · Double Chance · Over/Under · BTTS
          </Text>
        </View>
      </View>

      <View style={styles.activityRow}>
        <ActivityTile label="Results" value={activity.results} onPress={() => router.push("/(tabs)/fixtures")} />
        <ActivityTile label="Upcoming" value={activity.upcoming} onPress={() => router.push("/(tabs)/fixtures")} />
        <ActivityTile label="Matches" value={activity.total} onPress={() => router.push("/(tabs)/competitions")} />
      </View>

      <View style={styles.sectionHeader}>
        <Text variant="titleSmall" style={styles.sectionTitle}>
          Top Competitions
        </Text>
        <Pressable onPress={() => router.push("/(tabs)/competitions")} accessibilityRole="button">
          <Text variant="labelMedium" style={{ color: theme.colors.primary }}>
            View All
          </Text>
        </Pressable>
      </View>

      {topCompetitions.map((competition) => (
        <View key={competition.id} style={styles.item}>
          <CompetitionCard competition={competition} onPress={() => openCompetition(competition)} />
        </View>
      ))}

      <View style={styles.sectionHeader}>
        <Text variant="titleSmall" style={styles.sectionTitle}>
          Next Fixtures
        </Text>
        {season ? (
          <Text variant="labelSmall" style={styles.subtitle}>
            {season.name}
          </Text>
        ) : null}
      </View>

      {!season ? (
        <EmptyState title="No seasons yet" message="No competition has imported fixtures." />
      ) : upcomingQuery.isLoading ? (
        <ActivityIndicator color={theme.colors.primary} />
      ) : upcoming.length === 0 ? (
        <EmptyState
          title="No upcoming fixtures"
          message="The selected season has no scheduled matches left."
        />
      ) : (
        upcoming.map((match) => (
          <View key={match.id} style={styles.item}>
            <MatchCard
              match={match}
              homeTeam={teamNames.get(match.home_team_id) ?? `Team ${match.home_team_id}`}
              awayTeam={teamNames.get(match.away_team_id) ?? `Team ${match.away_team_id}`}
              onPress={openMatch}
            />
          </View>
        ))
      )}
    </ScrollView>
  );
}

function ActivityTile({
  label,
  value,
  onPress,
}: {
  label: string;
  value: number;
  onPress: () => void;
}) {
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={`${label}: ${value}`}
      style={({ pressed }) => [styles.tile, pressed ? styles.tilePressed : null]}
      testID={`activity-${label.toLowerCase()}`}
    >
      <Text variant="titleLarge" style={styles.tileValue}>
        {value.toLocaleString()}
      </Text>
      <Text variant="labelSmall" style={styles.tileLabel}>
        {label}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  content: {
    padding: layout.screenPadding,
    paddingBottom: layout.listBottomInset,
    gap: spacing.medium,
  },
  header: {
    marginBottom: spacing.xsmall,
  },
  title: {
    fontWeight: "700",
  },
  subtitle: {
    opacity: 0.7,
  },
  hero: {
    backgroundColor: palette.surface,
    borderRadius: radius.panel,
    borderWidth: 1,
    borderColor: palette.border,
    padding: spacing.standard,
    overflow: "hidden",
    gap: 4,
  },
  heroGlow: {
    position: "absolute",
    right: -40,
    top: -40,
    width: 140,
    height: 140,
    borderRadius: 70,
    backgroundColor: palette.primary,
    opacity: 0.18,
  },
  heroTitle: {
    fontWeight: "700",
  },
  heroSubtitle: {
    opacity: 0.8,
  },
  heroRow: {
    flexDirection: "row",
    marginTop: spacing.small,
  },
  heroMeta: {
    opacity: 0.65,
  },
  activityRow: {
    flexDirection: "row",
    gap: spacing.medium,
  },
  tile: {
    flex: 1,
    backgroundColor: palette.surface,
    borderRadius: radius.card,
    borderWidth: 1,
    borderColor: palette.border,
    paddingVertical: spacing.medium,
    alignItems: "center",
    gap: 2,
  },
  tilePressed: {
    backgroundColor: palette.surfaceElevated,
  },
  tileValue: {
    fontWeight: "700",
  },
  tileLabel: {
    opacity: 0.7,
  },
  sectionHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginTop: spacing.small,
  },
  sectionTitle: {
    fontWeight: "600",
  },
  item: {
    marginBottom: spacing.small,
  },
});
