/**
 * Competitions — browse the competitions the backend actually serves.
 *
 * Data: `useCompetitions()` → `GET /api/v1/competitions`. That response carries
 * `region`, `seasons`, `current_season` and `match_count`, so:
 *
 *  - the region filter groups by the SAME regions the backend uses (it was a
 *    client-side country list before, which meant the app and the server disagreed
 *    about what "Europe" meant and new competitions fell into "Other");
 *  - the card shows the season and fixture count that really exist rather than a
 *    placeholder.
 *
 * Search covers name, country and region, so "brazil" and "europe" both work.
 * Nothing is requested beyond the list endpoint: the screen is one round trip.
 */
import { useMemo, useState } from "react";
import { FlatList, RefreshControl, StyleSheet, View } from "react-native";
import { useRouter } from "expo-router";
import { Searchbar, Text } from "react-native-paper";

import { EmptyState, ErrorState, LoadingState } from "@/components/ScreenState";
import { CompetitionCard } from "@/components/CompetitionCard";
import { FilterChips } from "@/components/FilterChips";
import type { FilterOption } from "@/components/FilterChips";
import { useCompetitions } from "@/hooks/useApi";
import { layout, spacing } from "@/theme/theme";
import { useAppTheme } from "@/theme/useAppTheme";
import type { Competition } from "@/types/api";

/**
 * Region filter options. `all` is a client-side value; every other value is a
 * region the API returns, so a competition can never fall outside every filter.
 */
type RegionFilter =
  | "all"
  | "europe"
  | "south_america"
  | "africa"
  | "asia"
  | "north_america"
  | "other";

const REGION_OPTIONS: readonly FilterOption<RegionFilter>[] = [
  { value: "all", label: "All" },
  { value: "europe", label: "Europe" },
  { value: "south_america", label: "South America" },
  { value: "africa", label: "Africa" },
  { value: "asia", label: "Asia" },
  { value: "north_america", label: "North America" },
  { value: "other", label: "Other" },
];

export function filterCompetitions(
  competitions: readonly Competition[],
  region: RegionFilter,
  query: string,
): Competition[] {
  const needle = query.trim().toLowerCase();
  return competitions.filter((competition) => {
    const matchesRegion = region === "all" || competition.region === region;
    if (!matchesRegion) return false;
    if (needle.length === 0) return true;
    return [
      competition.name,
      competition.country,
      competition.region,
      competition.code,
    ]
      .filter((value): value is string => typeof value === "string")
      .some((value) => value.toLowerCase().includes(needle));
  });
}

export default function CompetitionsScreen() {
  const theme = useAppTheme();
  const router = useRouter();
  const [region, setRegion] = useState<RegionFilter>("all");
  const [query, setQuery] = useState("");

  const competitionsQuery = useCompetitions();
  const competitions = useMemo(
    () => competitionsQuery.data ?? [],
    [competitionsQuery.data],
  );

  // Only offer a region that has at least one competition: showing "Africa" as a
  // filter that always yields an empty list is a promise the data cannot keep.
  const availableRegions = useMemo(() => {
    const present = new Set(
      competitions.map((competition) => competition.region),
    );
    return REGION_OPTIONS.filter(
      (option) => option.value === "all" || present.has(option.value),
    );
  }, [competitions]);

  const filtered = useMemo(
    () => filterCompetitions(competitions, region, query),
    [competitions, region, query],
  );

  if (competitionsQuery.isLoading) {
    return <LoadingState message="Loading competitions…" />;
  }

  if (competitionsQuery.error) {
    return (
      <ErrorState
        error={competitionsQuery.error}
        onRetry={() => {
          void competitionsQuery.refetch();
        }}
      />
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text variant="headlineSmall" style={styles.title}>
          Competitions
        </Text>
        <Searchbar
          placeholder="Search league, country or region"
          value={query}
          onChangeText={setQuery}
          style={styles.search}
          inputStyle={styles.searchInput}
          iconColor={theme.app.textMuted}
          accessibilityLabel="Search competitions"
          testID="competitions-search"
        />
      </View>

      <FilterChips
        options={availableRegions}
        value={region}
        onChange={setRegion}
        testIDPrefix="region"
      />

      <FlatList
        data={filtered}
        keyExtractor={(competition) => String(competition.id)}
        contentContainerStyle={styles.list}
        refreshControl={
          <RefreshControl
            refreshing={competitionsQuery.isRefetching}
            onRefresh={() => {
              void competitionsQuery.refetch();
            }}
            tintColor={theme.colors.primary}
          />
        }
        renderItem={({ item }) => (
          <View style={styles.item}>
            <CompetitionCard
              competition={item}
              onPress={() => {
                void router.push(`/competitions/${item.id}`);
              }}
            />
          </View>
        )}
        ListEmptyComponent={
          competitions.length === 0 ? (
            <EmptyState
              title="No competitions available"
              message="The backend has not imported any competitions yet."
            />
          ) : (
            <EmptyState
              title="No matches for this filter"
              message="Try a different region or clear the search."
            />
          )
        }
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  header: {
    paddingHorizontal: layout.screenPadding,
    paddingTop: spacing.medium,
    gap: spacing.medium,
  },
  title: {
    fontWeight: "700",
  },
  search: {
    backgroundColor: "#0B1B2D",
    borderRadius: 10,
  },
  searchInput: {
    fontSize: 14,
  },
  list: {
    paddingHorizontal: layout.screenPadding,
    paddingBottom: layout.listBottomInset,
    flexGrow: 1,
  },
  item: {
    marginBottom: spacing.medium,
  },
});
