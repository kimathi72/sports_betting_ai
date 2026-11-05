import { StyleSheet, View } from "react-native";
import { IconButton, Text } from "react-native-paper";

import { CompetitionLogo } from "@/components/CompetitionLogo";
import { CountryFlag } from "@/components/CountryFlag";
import { PressableCard } from "@/components/PressableCard";
import { spacing } from "@/theme/tokens";
import { useAppTheme } from "@/theme/useAppTheme";
import type { Competition } from "@/types/api";

interface CompetitionCardProps {
  competition: Competition;
  onPress: () => void;
  /** Whether this competition is a favourite; undefined hides the control. */
  isFavourite?: boolean;
  onToggleFavourite?: () => void;
}

/**
 * One competition in a list: logo, name, country with flag, the latest available
 * season and how many fixtures it has.
 *
 * The season and match count come from the API (`seasons`, `current_season`,
 * `match_count`) and are only shown when present. A competition with no fixtures
 * therefore reads "No fixtures yet" rather than "0 matches", which would suggest
 * an empty but scheduled league.
 */
export function CompetitionCard({
  competition,
  onPress,
  isFavourite,
  onToggleFavourite,
}: CompetitionCardProps) {
  const theme = useAppTheme();
  const seasonLabel = competition.current_season ?? "No season data";
  const fixtureLabel =
    competition.match_count > 0
      ? `${competition.match_count.toLocaleString()} matches`
      : "No fixtures yet";

  return (
    <PressableCard
      onPress={onPress}
      accessibilityLabel={`${competition.name}${competition.country ? `, ${competition.country}` : ""}, ${fixtureLabel}`}
      testID={`competition-card-${competition.id}`}
      style={{ borderColor: theme.colors.outline }}
    >
      <View style={styles.row}>
        <CompetitionLogo
          code={competition.code}
          name={competition.name}
          size="card"
        />

        <View style={styles.meta}>
          <Text variant="titleSmall" numberOfLines={1}>
            {competition.name}
          </Text>
          <View style={styles.countryRow}>
            <CountryFlag country={competition.country} size="small" />
            <Text variant="bodySmall" style={styles.muted} numberOfLines={1}>
              {competition.country ?? "International"}
            </Text>
          </View>
          <Text variant="labelSmall" style={styles.muted}>
            {seasonLabel} · {fixtureLabel}
          </Text>
        </View>

        {onToggleFavourite ? (
          <IconButton
            icon={isFavourite ? "star" : "star-outline"}
            size={20}
            iconColor={
              isFavourite
                ? theme.app.warning
                : theme.colors.onSurfaceVariant
            }
            onPress={onToggleFavourite}
            accessibilityLabel={
              isFavourite
                ? `Remove ${competition.name} from favourites`
                : `Add ${competition.name} to favourites`
            }
            testID={`competition-favourite-${competition.id}`}
          />
        ) : null}
      </View>
    </PressableCard>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: "row",
    alignItems: "center",
    gap: spacing.medium,
  },
  meta: {
    flex: 1,
    gap: 2,
  },
  countryRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
  },
  muted: {
    opacity: 0.75,
  },
});
