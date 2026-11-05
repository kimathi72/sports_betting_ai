/**
 * Design tokens — the single source of colour, spacing, radius and type.
 *
 * Nothing in `app/` or `src/components/` may contain a raw hex value, a magic
 * pixel gap or an ad-hoc font size. Those must come from here, via the theme, so
 * a future light theme is a token swap rather than a hunt through screens.
 *
 * The palette is the approved midnight-navy / analytics-green identity. Every
 * colour below is either part of that identity or a semantic state colour.
 */

/** Core identity palette. */
export const palette = {
  background: "#071321",
  backgroundSecondary: "#142A42",
  surface: "#0B1B2D",
  surfaceElevated: "#10243A",
  primary: "#2478F2",
  primaryHighlight: "#35A0FF",
  textPrimary: "#F4F7FC",
  textSecondary: "#A9B9CC",
  textMuted: "#71869E",
  border: "#203A54",
} as const;

/**
 * Semantic states.
 *
 * These exist so screens ask for `success`/`danger` rather than re-deciding
 * what green means. Green reinforces a state that is also stated in words —
 * status text is never omitted, so colour is never the only signal.
 */
export const semantic = {
  success: "#20C997",
  successHighlight: "#2EDCA9",
  danger: "#F15B64",
  warning: "#F2B544",
  info: "#35A0FF",
  neutral: "#71869E",
} as const;

/**
 * 4px base spacing scale.
 *
 * `standard` is the screen gutter and card padding depth used throughout the
 * mockup (16px); `section` is the gap BETWEEN sections (24px), which is larger
 * than the gap between cards (16px) so grouping is visible without dividers.
 */
export const spacing = {
  xsmall: 4,
  small: 8,
  medium: 12,
  standard: 16,
  section: 24,
  large: 24,
  xlarge: 32,
  xxlarge: 40,
} as const;

export const radius = {
  control: 8,
  button: 10,
  card: 12,
  panel: 14,
  round: 999,
} as const;

/** Minimum interactive size. Used for buttons and icon targets. */
export const touchTarget = 44;

/**
 * Typography scale.
 *
 * `fontFamily` values are the keys registered by `useFonts` in
 * `AppProviders`. Inter is loaded in exactly the weights used below (400/500/
 * 600/700); loading extra variants would bloat the bundle for no visual gain.
 */
export const fontFamily = {
  regular: "Inter_400Regular",
  medium: "Inter_500Medium",
  semiBold: "Inter_600SemiBold",
  bold: "Inter_700Bold",
} as const;

export const typography = {
  display: { fontFamily: fontFamily.bold, fontSize: 30, lineHeight: 38 },
  h1: { fontFamily: fontFamily.bold, fontSize: 24, lineHeight: 32 },
  h2: { fontFamily: fontFamily.semiBold, fontSize: 20, lineHeight: 28 },
  h3: { fontFamily: fontFamily.semiBold, fontSize: 16, lineHeight: 24 },
  body: { fontFamily: fontFamily.regular, fontSize: 14, lineHeight: 21 },
  caption: { fontFamily: fontFamily.regular, fontSize: 12, lineHeight: 18 },
  small: { fontFamily: fontFamily.medium, fontSize: 11, lineHeight: 16 },
  numericLarge: {
    fontFamily: fontFamily.semiBold,
    fontSize: 28,
    lineHeight: 34,
  },
  numericMedium: {
    fontFamily: fontFamily.semiBold,
    fontSize: 20,
    lineHeight: 26,
  },
} as const;

/**
 * Tabular numerals.
 *
 * Percentages, scores and dates must not jitter as digits change width. Applied
 * to numeric text so a column of probabilities stays aligned.
 */
export const numericText = {
  fontVariant: ["tabular-nums"] as const,
} as const;

export type TypographyVariant = keyof typeof typography;
