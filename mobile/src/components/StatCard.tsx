/**
 * A single metric: label, value, optional caption.
 *
 * The value is always rendered from real data passed in. There is deliberately
 * no default or placeholder value — a caller with no number must not render a
 * card, so a missing metric cannot appear as "0" and read as a measurement.
 */
import { StyleSheet, View } from "react-native";
import { Text } from "react-native-paper";

import { useAppTheme } from "@/theme/useAppTheme";
import { numericText } from "@/theme/tokens";

interface StatCardProps {
  label: string;
  value: string;
  caption?: string;
  /** Tints the value. Never the only signal: the caption states the meaning. */
  tone?: "default" | "success" | "warning" | "danger" | "neutral";
  testID?: string;
}

export function StatCard({
  label,
  value,
  caption,
  tone = "default",
  testID,
}: StatCardProps) {
  const theme = useAppTheme();

  const toneColour = {
    default: theme.colors.onSurface,
    success: theme.app.success,
    warning: theme.app.warning,
    danger: theme.app.danger,
    neutral: theme.app.neutral,
  }[tone];

  return (
    <View
      testID={testID}
      style={[
        styles.card,
        {
          backgroundColor: theme.colors.surface,
          borderColor: theme.colors.outline,
          borderRadius: theme.radius.card,
        },
      ]}
    >
      <Text variant="labelMedium" style={{ color: theme.app.textMuted }}>
        {label}
      </Text>
      <Text
        style={[
          theme.typography.numericMedium,
          numericText,
          { color: toneColour },
        ]}
      >
        {value}
      </Text>
      {caption ? (
        <Text
          variant="bodySmall"
          style={{ color: theme.colors.onSurfaceVariant }}
        >
          {caption}
        </Text>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    flex: 1,
    padding: 16,
    borderWidth: 1,
    minHeight: 96,
    gap: 4,
  },
});
