/**
 * A section title with an optional trailing action.
 *
 * Centralised so the heading level, spacing and "View all" affordance are
 * identical on every screen.
 */
import { StyleSheet, View } from "react-native";
import { Button, Text } from "react-native-paper";

import { useAppTheme } from "@/theme/useAppTheme";

interface SectionHeaderProps {
  title: string;
  actionLabel?: string;
  onAction?: () => void;
  actionAccessibilityLabel?: string;
}

export function SectionHeader({
  title,
  actionLabel,
  onAction,
  actionAccessibilityLabel,
}: SectionHeaderProps) {
  const theme = useAppTheme();

  return (
    <View style={styles.row}>
      <Text variant="titleMedium" style={{ color: theme.colors.onSurface }}>
        {title}
      </Text>
      {actionLabel && onAction ? (
        <Button
          mode="text"
          compact
          onPress={onAction}
          textColor={theme.colors.primary}
          accessibilityLabel={actionAccessibilityLabel ?? actionLabel}
          style={styles.action}
        >
          {actionLabel}
        </Button>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginTop: 8,
    marginBottom: 8,
    minHeight: 44,
  },
  action: {
    marginRight: -8,
  },
});
