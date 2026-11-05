/**
 * Typed access to the app theme.
 *
 * `useTheme()` from Paper returns `MD3Theme`, which does not know about
 * `theme.app`, `theme.spacing` or `theme.radius`. Re-asserting the type at every
 * call site (`useTheme() as AppTheme`) is the kind of cast that silently breaks
 * when the theme changes, so it is asserted in exactly one place.
 */
import { useTheme } from "react-native-paper";

import type { AppTheme } from "@/theme/theme";

export function useAppTheme(): AppTheme {
  return useTheme() as AppTheme;
}
