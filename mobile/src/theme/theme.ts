/**
 * Application theme — dark-only MVP, built entirely from `tokens.ts`.
 *
 * WHY A FACTORY
 * -------------
 * `createTheme()` takes a token set and returns an MD3 theme plus the app's
 * semantic colours. A future light theme is therefore a second token set passed
 * to the same factory; no component changes, because no component reads a raw
 * colour. Only `darkTheme` is exported for now — implementing light is
 * deliberately out of scope.
 *
 * WHY NOT `MD3DarkTheme` SPREAD DIRECTLY
 * --------------------------------------
 * MD3's defaults are tuned for a generic dark surface. This identity is a
 * specific midnight navy, and several MD3 defaults (elevation tints, outline
 * greys) would drift from the palette. Every colour the app can actually use is
 * therefore set explicitly below.
 */
import { createPaperFonts } from '@/theme/paperFonts';
import { MD3DarkTheme, type MD3Theme } from "react-native-paper";

import {
  palette,
  radius,
  semantic,
  spacing,
  typography,
  type TypographyVariant,
} from "@/theme/tokens";

/** The app-specific colours the MD3 palette has no slot for. */
export interface AppColors {
  backgroundSecondary: string;
  surfaceElevated: string;
  textMuted: string;
  success: string;
  successHighlight: string;
  danger: string;
  warning: string;
  info: string;
  neutral: string;
}

export interface AppTheme extends MD3Theme {
  app: AppColors;
  spacing: typeof spacing;
  radius: typeof radius;
  typography: Record<TypographyVariant, (typeof typography)[TypographyVariant]>;
}

/**
 * Builds a theme from an explicit token set.
 *
 * `elevation.levels` is flattened to 0: Material's elevation tint lightens
 * surfaces with white, which fights the navy palette. Depth is conveyed with
 * borders and the surface/background steps instead.
 */
/**
 * Structural palette types.
 *
 * `typeof palette` would narrow each value to its exact hex literal, so a caller
 * could only ever pass the dark palette back in — which defeats the purpose of a
 * factory. Keying by name with `string` values is what lets a light theme be
 * added without touching this file.
 */
export type Palette = Record<keyof typeof palette, string>;
export type SemanticStates = Record<keyof typeof semantic, string>;

export function createTheme(colors: Palette, states: SemanticStates): AppTheme {
  return {
    ...MD3DarkTheme,
    // Inter everywhere, including Paper's own components.
    fonts: createPaperFonts(),
    colors: {
      ...MD3DarkTheme.colors,
      primary: colors.primary,
      onPrimary: "#FFFFFF",
      primaryContainer: colors.surfaceElevated,
      onPrimaryContainer: colors.primaryHighlight,

      secondary: states.info,
      onSecondary: "#FFFFFF",

      background: colors.background,
      onBackground: colors.textPrimary,

      surface: colors.surface,
      onSurface: colors.textPrimary,
      surfaceVariant: colors.backgroundSecondary,
      onSurfaceVariant: colors.textSecondary,

      surfaceDisabled: colors.surface,
      onSurfaceDisabled: colors.textMuted,

      outline: colors.border,
      outlineVariant: colors.border,

      error: states.danger,
      onError: "#FFFFFF",
      errorContainer: colors.surfaceElevated,
      onErrorContainer: states.danger,

      elevation: {
        level0: "transparent",
        level1: colors.surface,
        level2: colors.surfaceElevated,
        level3: colors.surfaceElevated,
        level4: colors.surfaceElevated,
        level5: colors.surfaceElevated,
      },
    },
    app: {
      backgroundSecondary: colors.backgroundSecondary,
      surfaceElevated: colors.surfaceElevated,
      textMuted: colors.textMuted,
      success: states.success,
      successHighlight: states.successHighlight,
      danger: states.danger,
      warning: states.warning,
      info: states.info,
      neutral: states.neutral,
    },
    spacing,
    radius,
    typography,
  };
}

export const darkTheme: AppTheme = createTheme(palette, semantic);

/** The active theme. One export, so switching mode later touches one line. */
export const theme: AppTheme = darkTheme;

/**
 * Re-exported so screens can import layout tokens from one module.
 *
 * `app/(tabs)/competitions/index.tsx` imports `layout` and `spacing` from here;
 * without this the name resolves to nothing and the screen fails to compile.
 * The value is the same object as `tokens.spacing` — not a copy — so the scale
 * still has one definition.
 */
export { spacing };

/**
 * Shared layout metrics. Screens use these for padding and the bottom inset so
 * content is never hidden behind the tab bar.
 */
export const layout = {
  screenPadding: spacing.standard,
  listBottomInset: 96,
} as const;
