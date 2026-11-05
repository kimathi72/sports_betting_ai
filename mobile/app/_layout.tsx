/**
 * Root layout.
 *
 * A Stack wraps the tab navigator so a match detail screen can be pushed ABOVE
 * the tab bar. Declaring `matches/[id]` directly as a Tabs.Screen does not work:
 * a tab cannot host a nested path segment, and navigating to it silently fell
 * back to the first tab.
 *
 * Providers live here, so every route — tab or detail — is inside the query
 * client and the Paper theme.
 */
import { Stack } from 'expo-router';

import { AppProviders } from '@/components/AppProviders';

export default function RootLayout() {
  return (
    <AppProviders>
      <Stack>
        <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
        <Stack.Screen name="matches/[id]" options={{ title: 'Match' }} />
      </Stack>
    </AppProviders>
  );
}
