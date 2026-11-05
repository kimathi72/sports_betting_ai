/**
 * Maps Inter onto React Native Paper's typography variants.
 *
 * Paper's default variants hardcode the platform font. Without this mapping the
 * app would render mostly in the system font with Inter appearing only where a
 * screen set a family explicitly — a subtle, easy-to-miss inconsistency.
 *
 * Sizes come from the approved scale in `tokens.ts`, so Paper components
 * (Card.Title, List.Item, Button labels…) match the app's own text.
 */
import type { MD3Theme } from "react-native-paper";

import { typography } from "@/theme/tokens";

type PaperFonts = MD3Theme["fonts"];

export function createPaperFonts(): PaperFonts {
  return {
    displayLarge: typography.display,
    displayMedium: typography.display,
    displaySmall: typography.h1,
    headlineLarge: typography.h1,
    headlineMedium: typography.h2,
    headlineSmall: typography.h3,
    titleLarge: typography.h2,
    titleMedium: typography.h3,
    titleSmall: typography.body,
    bodyLarge: typography.body,
    bodyMedium: typography.body,
    bodySmall: typography.caption,
    labelLarge: typography.h3,
    labelMedium: typography.small,
    labelSmall: typography.small,
    // Paper 5 types `fonts` as a fixed record; the cast keeps the object
    // readable rather than restating every variant name twice.
  } as unknown as PaperFonts;
}
