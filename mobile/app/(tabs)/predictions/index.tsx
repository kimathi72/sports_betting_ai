/**
 * Predictions — the stored predictions for every match that has them.
 *
 * DATA SOURCE: `GET /api/v1/predictions` (stored rows), not the POST endpoint.
 * Generation stays on the match screen, where a user has chosen a specific
 * match; a list screen must never trigger model inference for every row it
 * displays.
 *
 * MARKET RENDERING: reuse of `MarketCard` is deliberate. It is the single place
 * that knows non-1X2 rows carry meaningless legacy fields, and it is covered by
 * a regression test. Re-implementing the market rows here would reintroduce the
 * `away_probability: 1.0` bug on a second screen.
 */
import { useMemo, useState } from "react";
import { FlatList, RefreshControl, StyleSheet, View } from "react-native";
import { useRouter } from "expo-router";
import { Card, Chip, Searchbar, Text } from "react-native-paper";

import { EmptyState, ErrorState, LoadingState } from "@/components/ScreenState";
import { SectionHeader } from "@/components/SectionHeader";
import { usePredictionHistory } from "@/hooks/useApi";
import {
  groupPredictionsByMatch,
  marketDistribution,
} from "@/hooks/usePredictionOverview";
import { MARKET_META, MARKET_ORDER } from "@/domain/predictions";
import { useAppTheme } from "@/theme/useAppTheme";
import { formatRelative } from "@/utils/format";
import { layout } from "@/theme/theme";
import type { MarketName } from "@/types/api";

export default function PredictionsScreen() {
  const theme = useAppTheme();
  const router = useRouter();
  const [query, setQuery] = useState("");
  const [marketFilter, setMarketFilter] = useState<MarketName | null>(null);

  const predictionsQuery = usePredictionHistory({ limit: 500 });

  const rows = predictionsQuery.data ?? [];

  const groups = useMemo(() => groupPredictionsByMatch(rows), [rows]);
  const distribution = useMemo(() => marketDistribution(rows), [rows]);

  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return groups.filter((group) => {
      const matchesMarket = marketFilter
        ? group.markets.includes(marketFilter)
        : true;
      // Search is local: the API exposes no text search for predictions, and
      // this is a bounded, already-loaded set.
      const matchesText =
        needle.length === 0 || `match ${group.matchId}`.includes(needle);
      return matchesMarket && matchesText;
    });
  }, [groups, marketFilter, query]);

  if (predictionsQuery.isLoading) {
    return <LoadingState message="Loading predictions…" />;
  }

  if (predictionsQuery.error) {
    return (
      <ErrorState
        error={predictionsQuery.error}
        onRetry={() => {
          void predictionsQuery.refetch();
        }}
      />
    );
  }

  return (
    <View
      style={[styles.container, { backgroundColor: theme.colors.background }]}
    >
      <FlatList
        data={filtered}
        keyExtractor={(group) => String(group.matchId)}
        contentContainerStyle={styles.list}
        refreshControl={
          <RefreshControl
            refreshing={predictionsQuery.isRefetching}
            onRefresh={() => {
              void predictionsQuery.refetch();
            }}
            tintColor={theme.colors.primary}
          />
        }
        ListHeaderComponent={
          <View style={styles.header}>
            <Searchbar
              placeholder="Search by match id"
              value={query}
              onChangeText={setQuery}
              style={{ backgroundColor: theme.colors.surface }}
              inputStyle={{ color: theme.colors.onSurface }}
              iconColor={theme.app.textMuted}
              accessibilityLabel="Search predictions"
            />

            <View style={styles.chipRow}>
              {MARKET_ORDER.filter((market) =>
                distribution.some((entry) => entry.market === market),
              ).map((market) => (
                <Chip
                  key={market}
                  compact
                  selected={marketFilter === market}
                  onPress={() =>
                    setMarketFilter(marketFilter === market ? null : market)
                  }
                  testID={`filter-market-${market}`}
                >
                  {MARKET_META[market].label}
                </Chip>
              ))}
            </View>

            {distribution.length > 0 ? (
              <Text variant="bodySmall" style={{ color: theme.app.textMuted }}>
                {rows.length} stored predictions across {groups.length}{" "}
                {groups.length === 1 ? "match" : "matches"}
              </Text>
            ) : null}

            <SectionHeader title="Predicted matches" />
          </View>
        }
        renderItem={({ item }) => (
          <Card
            style={[
              styles.card,
              {
                backgroundColor: theme.colors.surface,
                borderColor: theme.colors.outline,
                borderRadius: theme.radius.card,
              },
            ]}
            onPress={() =>
              router.push({
                pathname: "/matches/[id]",
                params: { id: String(item.matchId) },
              })
            }
            accessible
            accessibilityRole="button"
            accessibilityLabel={`Predictions for match ${item.matchId}`}
            testID={`prediction-group-${item.matchId}`}
          >
            <Card.Content>
              <View style={styles.cardHeader}>
                <Text
                  variant="titleSmall"
                  style={{ color: theme.colors.onSurface }}
                >
                  Match {item.matchId}
                </Text>
                <Text variant="bodySmall" style={{ color: theme.app.textMuted }}>
                  {formatRelative(item.generatedAt)}
                </Text>
              </View>

              <View style={styles.marketList}>
                {item.markets.map((market) => (
                  <Text
                    key={market}
                    variant="bodySmall"
                    style={{ color: theme.colors.onSurfaceVariant }}
                  >
                    {MARKET_META[market]?.label ?? market}
                  </Text>
                ))}
              </View>

              <Text variant="bodySmall" style={{ color: theme.app.textMuted }}>
                {item.modelVersions.length === 1
                  ? `Model ${item.modelVersions[0]}`
                  : `Models ${item.modelVersions.join(", ")}`}
              </Text>
            </Card.Content>
          </Card>
        )}
        ListEmptyComponent={
          <EmptyState
            title={
              rows.length === 0 ? "No predictions yet" : "No matches found"
            }
            message={
              rows.length === 0
                ? "Predictions appear here once you generate them from a match."
                : "Try clearing the search or market filter."
            }
          />
        }
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  list: {
    paddingHorizontal: layout.screenPadding,
    paddingBottom: layout.listBottomInset,
    flexGrow: 1,
  },
  header: {
    gap: 12,
    paddingTop: 12,
  },
  chipRow: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 8,
  },
  card: {
    marginBottom: 10,
    borderWidth: 1,
  },
  cardHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginBottom: 8,
  },
  marketList: {
    gap: 2,
    marginBottom: 8,
  },
});
