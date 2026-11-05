/**
 * A fixture row in a list.
 *
 * Receives resolved team names rather than looking them up itself: the list
 * screen already holds the team and competition maps, and passing them down
 * keeps this component pure and trivially testable.
 */
import { StyleSheet, View } from "react-native";
import { Card, Text } from "react-native-paper";

import { useAppTheme } from "@/theme/useAppTheme";
import type { AppTheme } from "@/theme/theme";

import { formatKickoff, formatMatchStatus, formatScore } from "@/utils/format";
import type { Match } from "@/types/api";

interface MatchCardProps {
  match: Match;
  homeTeam: string;
  awayTeam: string;
  onPress: (match: Match) => void;
}

/**
 * Status colour. Colour is never the only signal — the label itself always
 * states the status — so this only reinforces it.
 */
function statusColour(status: string, fallback: string, app: AppTheme["app"]): string {
  switch (status) {
    case "completed":
      return app.success;
    case "in_progress":
      return app.warning;
    case "postponed":
    case "cancelled":
      return app.danger;
    default:
      return fallback;
  }
}

export function MatchCard({
  match,
  homeTeam,
  awayTeam,
  onPress,
}: MatchCardProps) {
  const theme = useAppTheme();
  const score = formatScore(match.home_score, match.away_score);
  const isCompleted = match.status === "completed";

  return (
    <Card
      style={[
        styles.card,
        {
          backgroundColor: theme.colors.surface,
          borderRadius: theme.radius.card,
          borderWidth: 1,
          borderColor: theme.colors.outline,
        },
      ]}
      onPress={() => onPress(match)}
      accessible
      accessibilityRole="button"
      accessibilityLabel={`${homeTeam} versus ${awayTeam}, ${formatMatchStatus(match.status)}`}
      testID={`match-card-${match.id}`}
    >
      <Card.Content>
        <View style={styles.header}>
          <Text variant="labelMedium">{formatKickoff(match.kickoff_at)}</Text>
          {/* A Chip renders a <button>; nesting it inside the pressable card
              produces invalid nested buttons. A Text label carries the same
              information without an interactive element inside a touch target. */}
          <Text
            variant="labelMedium"
            style={[styles.status, { color: statusColour(match.status, theme.colors.onSurface, theme.app) }]}
            testID={`match-status-${match.id}`}
          >
            {formatMatchStatus(match.status)}
          </Text>
        </View>

        <View style={styles.teams}>
          <View style={styles.teamColumn}>
            <Text variant="titleMedium" numberOfLines={1}>
              {homeTeam}
            </Text>
            <Text variant="titleMedium" numberOfLines={1}>
              {awayTeam}
            </Text>
          </View>

          {score ? (
            <Text
              variant="titleMedium"
              style={styles.score}
              testID={`match-score-${match.id}`}
            >
              {score}
            </Text>
          ) : (
            <Text variant="bodySmall" style={styles.kickoff}>
              {isCompleted ? "No score" : "vs"}
            </Text>
          )}
        </View>
      </Card.Content>
    </Card>
  );
}

const styles = StyleSheet.create({
  card: {
    marginBottom: 10,
  },
  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginBottom: 8,
  },
  teams: {
    flexDirection: "row",
    alignItems: "center",
  },
  teamColumn: {
    flex: 1,
    gap: 4,
  },
  score: {
    marginLeft: 12,
  },
  kickoff: {
    marginLeft: 12,
    opacity: 0.7,
  },
  status: {
    fontWeight: '600',
  },
});
