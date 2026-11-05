/**
 * Every provider the app needs, in one place.
 *
 * The root layout renders this, so a screen can never be mounted outside the
 * query client, the loaded fonts or the Paper theme. `QueryClient` is created
 * once per app instance, not per render — a per-render client would discard the
 * cache on any re-render.
 */
import { useEffect, useState } from "react";
import { View } from "react-native";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useFonts } from "expo-font";
import * as SplashScreen from "expo-splash-screen";
import { ActivityIndicator, PaperProvider, Snackbar } from "react-native-paper";

import { interFonts } from "@/theme/fonts";
import { theme } from "@/theme/theme";

// Keep the native splash up while fonts load, so no frame is ever painted with
// the system font and then reflowed into Inter. This is the only reason the
// app holds the splash: it must not be held for data.
void SplashScreen.preventAutoHideAsync().catch(() => {
  // A failure here is harmless (e.g. web, or a double call on fast refresh);
  // the fallback branch below still renders a spinner rather than a blank page.
});

interface AppProvidersProps {
  children: React.ReactNode;
  /** Injectable so tests can assert on cache state. */
  client?: QueryClient;
  /**
   * Skips waiting for fonts. Tests render components synchronously and have no
   * font asset binary to load, so blocking there would hang every test.
   */
  skipFontLoading?: boolean;
}

export function createQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      queries: {
        // One retry: a transient blip recovers without hammering a rate-limited
        // API, and a genuine outage surfaces quickly to the user.
        retry: 1,
        staleTime: 60 * 1000,
        refetchOnWindowFocus: false,
      },
      mutations: {
        // Prediction calls run model inference; retrying blindly would double
        // the load for a request that may genuinely have failed.
        retry: 0,
      },
    },
  });
}

export function AppProviders({
  children,
  client,
  skipFontLoading = false,
}: AppProvidersProps) {
  const [queryClient] = useState(() => client ?? createQueryClient());
  const [fontsLoaded, fontError] = useFonts(skipFontLoading ? {} : interFonts);

  const ready = skipFontLoading || fontsLoaded || fontError !== null;

  useEffect(() => {
    if (ready) {
      void SplashScreen.hideAsync().catch(() => undefined);
    }
  }, [ready]);

  if (!ready) {
    // A themed spinner on the app background, never a blank white frame.
    return (
      <View
        style={{
          flex: 1,
          alignItems: "center",
          justifyContent: "center",
          backgroundColor: theme.colors.background,
        }}
        accessibilityLabel="Starting"
        testID="font-loading"
      >
        <ActivityIndicator color={theme.colors.primary} />
      </View>
    );
  }

  // A font failure must not brick the app: Paper falls back to the platform
  // font and every screen still works, because nothing hardcodes a family.
  return (
    <QueryClientProvider client={queryClient}>
      <PaperProvider theme={theme}>{children}</PaperProvider>
    </QueryClientProvider>
  );
}

export { Snackbar };
