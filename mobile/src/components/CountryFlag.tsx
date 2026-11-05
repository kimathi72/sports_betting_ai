import { useMemo, useState } from "react";
import { Image, StyleSheet, View } from "react-native";

import { flagForCountry } from "@/assets/flags";
import { palette } from "@/theme/tokens";

export const FLAG_SIZES = {
  small: { width: 18, height: 13 },
  medium: { width: 24, height: 17 },
  large: { width: 32, height: 22 },
} as const;

export type FlagSize = keyof typeof FLAG_SIZES;

type Props = {
  /** Country name exactly as the API returns it ("England", "Spain", "Europe"). */
  country: string | null | undefined;
  size?: FlagSize;
};

/**
 * A country flag, or nothing at all.
 *
 * A flag is decorative context beside a country name that is always printed, so when
 * a country has no verified flag this renders a neutral outline rather than a wrong
 * flag or a broken image. Rendering nothing would shift the row's layout when some
 * countries have flags; the outline keeps columns aligned.
 */
export function CountryFlag({ country, size = "medium" }: Props) {
  const [failed, setFailed] = useState(false);
  const uri = useMemo(() => flagForCountry(country), [country]);
  const dimensions = FLAG_SIZES[size];

  if (!uri || failed) {
    return (
      <View
        style={[styles.unknown, dimensions]}
        accessible
        accessibilityRole="image"
        accessibilityLabel={
          country ? `${country} flag unavailable` : "flag unavailable"
        }
        testID="country-flag-fallback"
      />
    );
  }

  return (
    <Image
      source={{ uri }}
      style={[styles.flag, dimensions]}
      resizeMode="contain"
      onError={() => setFailed(true)}
      accessible
      accessibilityRole="image"
      accessibilityLabel={`${country} flag`}
      testID={`country-flag-${country}`}
    />
  );
}

const styles = StyleSheet.create({
  flag: {
    borderRadius: 2,
  },
  unknown: {
    borderRadius: 2,
    borderWidth: 1,
    borderColor: palette.border,
    backgroundColor: palette.surfaceElevated,
  },
});
