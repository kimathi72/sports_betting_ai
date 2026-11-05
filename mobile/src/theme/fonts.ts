/**
 * Inter font loading.
 *
 * Only the four weights the typography scale actually uses are requested. Each
 * extra weight is a separate TTF in the bundle, so loading Inter_900Black
 * "just in case" costs the user for nothing.
 *
 * The keys here MUST match `fontFamily` in `tokens.ts`; Paper looks the family
 * up by string, so a mismatch silently falls back to the system font (the
 * `theme.test.ts` assertion catches that).
 */
import {
  Inter_400Regular,
  Inter_500Medium,
  Inter_600SemiBold,
  Inter_700Bold,
} from "@expo-google-fonts/inter";

export const interFonts = {
  Inter_400Regular,
  Inter_500Medium,
  Inter_600SemiBold,
  Inter_700Bold,
} as const;
