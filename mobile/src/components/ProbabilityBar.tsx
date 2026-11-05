/**
 * One outcome row inside a market card: label, bar, percentage.
 */
import { StyleSheet, View } from "react-native";
import { Text, useTheme } from "react-native-paper";

interface ProbabilityBarProps {
  label: string;
  probability: number;
  /** Highlights the most likely outcome. */
  highlighted?: boolean;
}

export function ProbabilityBar({
  label,
  probability,
  highlighted = false,
}: ProbabilityBarProps) {
  const theme = useTheme();
  // Clamp: a misbehaving provider response must not overflow the bar.
  const clamped = Math.max(0, Math.min(1, probability));
  const percent = `${(clamped * 100).toFixed(1)}%`;

  return (
    <View
      style={styles.row}
      accessible
      accessibilityLabel={`${label}: ${percent}`}
    >
      <Text
        variant={highlighted ? "labelLarge" : "bodyMedium"}
        style={styles.label}
        numberOfLines={1}
      >
        {label}
      </Text>
      <View
        style={[styles.track, { backgroundColor: theme.colors.surfaceVariant }]}
      >
        <View
          testID="probability-fill"
          style={[
            styles.fill,
            {
              width: `${clamped * 100}%`,
              backgroundColor: highlighted
                ? theme.colors.primary
                : theme.colors.secondary,
            },
          ]}
        />
      </View>
      <Text variant="labelMedium" style={styles.value}>
        {percent}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: "row",
    alignItems: "center",
    marginVertical: 4,
  },
  label: {
    width: 108,
  },
  track: {
    flex: 1,
    height: 8,
    borderRadius: 4,
    overflow: "hidden",
  },
  fill: {
    height: "100%",
    borderRadius: 4,
  },
  value: {
    width: 56,
    textAlign: "right",
  },
});
