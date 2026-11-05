/**
 * Global test setup.
 *
 * The environment module reads EXPO_PUBLIC_API_BASE_URL at import time and
 * throws when it is missing (deliberately — a misconfigured build must fail
 * loudly, not silently call the wrong host). Tests therefore set it here rather
 * than in every spec, and specs that assert the failure path re-import the
 * module with the variable removed.
 */


process.env.EXPO_PUBLIC_API_BASE_URL = "http://localhost:3000";
process.env.EXPO_PUBLIC_APP_ENV = "test";
process.env.EXPO_PUBLIC_APP_VERSION = "1.0.0";

/**
 * Fonts cannot load in Jest: there is no asset registry, so `useFonts` throws
 * "Module 1 is missing from the asset registry" as soon as any component tree
 * reaches `AppProviders`. Reporting fonts as loaded is the honest stub — the
 * binary is not under test here, and every screen is exercised with the family
 * names the theme declares.
 */
jest.mock('expo-font', () => ({
  useFonts: () => [true, null],
  isLoaded: () => true,
  loadAsync: () => Promise.resolve(),
}));

jest.mock('expo-splash-screen', () => ({
  preventAutoHideAsync: () => Promise.resolve(),
  hideAsync: () => Promise.resolve(),
}));
