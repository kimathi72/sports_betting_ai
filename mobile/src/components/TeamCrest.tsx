import { useMemo, useState } from "react";
import { Image, StyleSheet, Text, View } from "react-native";

import { crestForTeam } from "@/assets/teamCrests";
import { palette, radius } from "@/theme/tokens";

/** Crest size steps, matching the mockup: rows 28–34px, details 64–80px. */
export const CREST_SIZES = {
  table: 24,
  fixture: 30,
  predictionCard: 36,
  competitionCard: 32,
  matchDetail: 72,
} as const;

export type CrestSize = keyof typeof CREST_SIZES;

type Props = {
  /** Canonical team name as returned by the Rails API. */
  name: string;
  size?: CrestSize;
};

/**
 * A club crest, with an honest fallback.
 *
 * Sourcing order (see `src/assets/teamCrests.ts`): a verified CDN URL for the club,
 * otherwise a MONOGRAM — the club's initials on the card surface.
 *
 * What this deliberately does NOT do:
 *  - guess a similarly-named club's badge, which shows the user the wrong team;
 *  - use an emoji, which is not a crest;
 *  - draw a generic shield, which pretends every unknown club has a logo.
 *
 * A monogram is unambiguous: the user sees the right club name and understands the
 * badge is unavailable. `onError` also degrades to the monogram, so a CDN outage
 * cannot leave a broken image placeholder in the list.
 */
export function TeamCrest({ name, size = "fixture" }: Props) {
  const [failed, setFailed] = useState(false);
  const uri = useMemo(() => crestForTeam(name), [name]);
  const dimension = CREST_SIZES[size];

  if (!uri || failed) {
    return <CrestMonogram name={name} dimension={dimension} />;
  }

  return (
    <Image
      source={{ uri }}
      style={{ width: dimension, height: dimension }}
      resizeMode="contain"
      onError={() => setFailed(true)}
      // DEFAULT_SOURCE is not used: an empty source renders the platform's broken
      // image glyph for a frame. The `failed` state swaps the whole element for the
      // monogram instead, which is the only way to change what is rendered.
      accessible
      accessibilityRole="image"
      accessibilityLabel={`${name} crest`}
      testID={`team-crest-${name}`}
    />
  );
}

/** The initials shown when no verified crest exists. */
export function crestInitials(name: string): string {
  const words = name
    .replace(/[^\p{L}\p{N}\s.]/gu, " ")
    .split(/\s+/)
    .filter(
      (word) =>
        word.length > 0 &&
        !/^(fc|afc|cf|sc|ac|as|ssc|club|de|the)$/i.test(word),
    );
  // A club named with a single significant word ("Arsenal", "Barcelona") gets two
  // letters from that word: one letter would read as a bullet rather than an
  // abbreviation. Only a name with nothing left to use falls back to its raw chars.
  if (words.length === 1) {
    return words[0].slice(0, 2).toUpperCase();
  }

  const initials = words
    .slice(0, 2)
    .map((word) => word[0])
    .join("");
  if (initials.length > 0) return initials.toUpperCase();

  // Every word was a club-type word ("FC"): use the name rather than showing nothing.
  const raw = name.replace(/[^\p{L}\p{N}]/gu, "");
  return (raw.slice(0, 2) || "?").toUpperCase();
}

function CrestMonogram({
  name,
  dimension,
}: {
  name: string;
  dimension: number;
}) {
  return (
    <View
      style={[
        styles.monogram,
        {
          width: dimension,
          height: dimension,
          borderRadius: Math.max(radius.control - 2, dimension / 2),
        },
      ]}
      accessible
      accessibilityRole="image"
      accessibilityLabel={`${name} (crest unavailable)`}
      testID={`team-crest-fallback-${name}`}
    >
      <Text
        style={[
          styles.monogramText,
          { fontSize: Math.max(9, dimension * 0.34) },
        ]}
      >
        {crestInitials(name)}
      </Text>
    </View>
  );
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
