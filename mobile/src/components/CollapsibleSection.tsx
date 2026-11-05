/**
 * A collapsible section, used for one season on the Fixtures screen.
 *
 * WHY A SHARED COMPONENT
 * ----------------------
 * Expand/collapse has three obligations that are easy to get subtly wrong in a
 * screen: the accessible name must state the state, the control must be reachable
 * as a single toggle (not a heading and a separate chevron), and the collapsed
 * section must render nothing rather than a zero-height list. Those live here so
 * every section behaves identically.
 *
 * The component is presentation only. It does not fetch: whatever it renders is
 * passed in, which is what keeps expanding a section free of network traffic.
 */
import type { ReactNode } from "react";
import { Pressable, StyleSheet, View } from "react-native";
import { Icon, Text } from "react-native-paper";

import { radius, spacing } from "@/theme/tokens";
import { useAppTheme } from "@/theme/useAppTheme";

type Props = {
  title: string;
  /** Short secondary line, e.g. "11 matches". Never a fabricated count. */
  subtitle?: string | undefined;
  expanded: boolean;
  onToggle: () => void;
  /** Marks this section as the active/current season. */
  isCurrent?: boolean;
  children?: ReactNode;
  testID?: string;
};

export function CollapsibleSection({
  title,
  subtitle,
  expanded,
  onToggle,
  isCurrent = false,
  children,
  testID,
}: Props) {
  const theme = useAppTheme();

  return (
    <View style={styles.section}>
      <Pressable
        onPress={onToggle}
        accessibilityRole="button"
        // The label carries the state; a screen reader user should not have to
        // infer "open" from the chevron's direction.
        accessibilityLabel={`${title}, ${isCurrent ? "current season, " : ""}${
          expanded ? "expanded" : "collapsed"
        }`}
        accessibilityState={{ expanded }}
        testID={testID}
        style={({ pressed }) => [
          styles.header,
          {
            backgroundColor: theme.colors.surface,
            borderColor: isCurrent
              ? theme.colors.primary
              : theme.colors.outline,
            opacity: pressed ? 0.85 : 1,
          },
        ]}
      >
        <Icon
          source={expanded ? "chevron-down" : "chevron-right"}
          size={22}
          color={theme.colors.onSurfaceVariant}
        />
        <View style={styles.headerText}>
          <View style={styles.titleRow}>
            <Text
              variant="titleSmall"
              style={{ color: theme.colors.onSurface }}
            >
              {title}
            </Text>
            {isCurrent ? (
              <View
                style={[
                  styles.badge,
                  { backgroundColor: theme.colors.primaryContainer },
                ]}
              >
                <Text
                  variant="labelSmall"
                  style={{ color: theme.colors.primary }}
                >
                  Current
                </Text>
              </View>
            ) : null}
          </View>
          {subtitle ? (
            <Text
              variant="bodySmall"
              style={{ color: theme.colors.onSurfaceVariant }}
              numberOfLines={1}
            >
              {subtitle}
            </Text>
          ) : null}
        </View>
      </Pressable>

      {expanded ? <View style={styles.body}>{children}</View> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  section: {
    marginBottom: spacing.small,
  },
  header: {
    flexDirection: "row",
    alignItems: "center",
    gap: spacing.small,
    paddingVertical: spacing.medium,
    paddingHorizontal: spacing.standard,
    borderRadius: radius.card,
    borderWidth: 1,
    // Comfortably above the 44px minimum for a touch target.
    minHeight: 56,
  },
  headerText: {
    flex: 1,
    gap: 2,
  },
  titleRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: spacing.small,
  },
  badge: {
    paddingHorizontal: spacing.small,
    paddingVertical: 2,
    borderRadius: radius.round,
  },
  body: {
    paddingTop: spacing.small,
  },
});
