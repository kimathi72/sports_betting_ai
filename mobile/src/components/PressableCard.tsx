import type { ReactNode } from "react";
import { StyleSheet, View } from "react-native";
import type { StyleProp, ViewStyle } from "react-native";
import { Pressable } from "react-native";

import { palette, radius, spacing } from "@/theme/tokens";

type Props = {
  onPress?: () => void;
  children: ReactNode;
  accessibilityLabel: string;
  testID?: string;
  style?: StyleProp<ViewStyle>;
  /** Rendered padding; 12–16px per the design tokens. */
  padding?: number;
};

/**
 * The shared pressable surface for list rows and cards.
 *
 * Every tappable card in the app needs the same three things: an accessible role, a
 * pressed state that is visible on the dark surface, and a consistent card radius.
 * Repeating those in each card is how an app ends up with five subtly different row
 * heights and one row that is not reachable by a screen reader.
 */
export function PressableCard({
  onPress,
  children,
  accessibilityLabel,
  testID,
  style,
  padding = spacing.medium,
}: Props) {
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole={onPress ? "button" : undefined}
      accessibilityLabel={accessibilityLabel}
      testID={testID}
      style={({ pressed }) => [
        styles.card,
        { padding },
        pressed && onPress ? styles.pressed : null,
        style,
      ]}
    >
      {children}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: palette.surface,
    borderRadius: radius.card,
    borderWidth: 1,
    borderColor: palette.border,
  },
  pressed: {
    // A real pressed state: without one, a tap on a dark card gives no feedback.
    backgroundColor: palette.surfaceElevated,
  },
});

export const cardStyles = StyleSheet.create({
  row: {
    flexDirection: "row",
    alignItems: "center",
    gap: spacing.medium,
  },
  fill: {
    flex: 1,
  },
  // Keeps a row's secondary text from wrapping into two lines and changing the
  // height of a list as the user scrolls.
  singleLine: {
    flexShrink: 1,
  },
  separator: {
    height: StyleSheet.hairlineWidth,
    backgroundColor: palette.border,
  },
  container: {
    flex: 1,
    backgroundColor: palette.background,
  },
});

export function CardRow({ children }: { children: ReactNode }) {
  return <View style={cardStyles.row}>{children}</View>;
}
