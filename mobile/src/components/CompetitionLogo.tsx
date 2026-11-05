import { useMemo, useState } from "react";
import { Image, StyleSheet, Text, View } from "react-native";

import { logoForCompetition } from "@/assets/competitionLogos";
import { palette, radius } from "@/theme/tokens";

export const COMPETITION_LOGO_SIZES = {
  row: 22,
  card: 40,
  header: 56,
} as const;

export type CompetitionLogoSize = keyof typeof COMPETITION_LOGO_SIZES;

type Props = {
  /** The competition CODE the API returns (E0, SP1, uefa.champions, …). */
  code: string | null | undefined;
  /** Fallback label for the monogram and the accessibility name. */
  name: string;
  size?: CompetitionLogoSize;
};

/**
 * A competition badge, keyed by the competition code.
 *
 * The code is used rather than the display name because the API sends the code and
 * the name is presentation. A competition without a verified logo gets a monogram of
 * its name, so "Serie B" still reads as itself instead of showing Serie A's badge.
 */
export function CompetitionLogo({ code, name, size = "card" }: Props) {
  const [failed, setFailed] = useState(false);
  const uri = useMemo(() => logoForCompetition(code), [code]);
  const dimension = COMPETITION_LOGO_SIZES[size];

  if (!uri || failed) {
    return (
      <View
        style={[
          styles.monogram,
          { width: dimension, height: dimension, borderRadius: radius.control },
        ]}
        accessible
        accessibilityRole="image"
        accessibilityLabel={`${name} (logo unavailable)`}
        testID={`competition-logo-fallback-${code ?? name}`}
      >
        <Text
          style={[
            styles.monogramText,
            { fontSize: Math.max(8, dimension * 0.36) },
          ]}
        >
          {competitionInitials(name)}
        </Text>
      </View>
    );
  }

  return (
    <Image
      source={{ uri }}
      style={{ width: dimension, height: dimension }}
      resizeMode="contain"
      onError={() => setFailed(true)}
      accessible
      accessibilityRole="image"
      accessibilityLabel={`${name} logo`}
      testID={`competition-logo-${code ?? name}`}
    />
  );
}

export function competitionInitials(name: string): string {
  const words = name.split(/\s+/).filter(Boolean);
  if (words.length === 1) return words[0].slice(0, 2).toUpperCase();
  return words
    .slice(0, 2)
    .map((word) => word[0])
    .join("")
    .toUpperCase();
}

const styles = StyleSheet.create({
  monogram: {
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: palette.surfaceElevated,
    borderWidth: 1,
    borderColor: palette.border,
  },
  monogramText: {
    color: palette.textSecondary,
    fontWeight: "700",
  },
});
