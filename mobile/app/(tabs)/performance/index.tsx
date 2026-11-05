/**
 * Performance — model and prediction ACTIVITY.
 *
 * SCOPE (approved): this screen reports only what the API genuinely exposes —
 * how many predictions exist, which model versions produced them, and how those
 * predictions are distributed across markets.
 *
 * It deliberately does NOT report accuracy, hit rate, Brier score, log loss,
 * calibration or profitability. No endpoint provides them, and deriving any of
 * them from prediction volume would be fabrication. The "not available" block
 * below says so explicitly, so the absence reads as a known limitation rather
 * than a broken screen.
 */
import { ScrollView, StyleSheet, View } from "react-native";
import { Card, Divider, Text } from "react-native-paper";

import { EmptyState, ErrorState, LoadingState } from "@/components/ScreenState";
import { SectionHeader } from "@/components/SectionHeader";
import { StatCard } from "@/components/StatCard";
import { useModelStatus, usePredictionHistory } from "@/hooks/useApi";
import { marketDistribution } from "@/hooks/usePredictionOverview";
import { MARKET_META } from "@/domain/predictions";
import { useAppTheme } from "@/theme/useAppTheme";
import { formatRelative } from "@/utils/format";
import { layout } from "@/theme/theme";

export default function PerformanceScreen() {
  const theme = useAppTheme();
  const modelQuery = useModelStatus();
  const predictionsQuery = usePredictionHistory({ limit: 500 });

  if (modelQuery.isLoading || predictionsQuery.isLoading) {
    return <LoadingState message="Loading model activity…" />;
  }

  if (modelQuery.error || predictionsQuery.error) {
    return (
      <ErrorState
        error={modelQuery.error ?? predictionsQuery.error}
        onRetry={() => {
          void modelQuery.refetch();
          void predictionsQuery.refetch();
        }}
      />
    );
  }

  const model = modelQuery.data;
  const rows = predictionsQuery.data ?? [];
  const distribution = marketDistribution(rows);
  const totalPredictions = model?.prediction_count ?? 0;
  const predictedMatches = new Set(rows.map((row) => row.match_id)).size;
  const maxMarketCount = distribution[0]?.count ?? 0;

  return (
    <ScrollView
      style={{ backgroundColor: theme.colors.background }}
      contentContainerStyle={styles.content}
    >
      <SectionHeader title="Prediction activity" />

      {totalPredictions === 0 ? (
        <EmptyState
          title="No predictions recorded"
          message="Model activity appears here once a prediction has been generated for a match."
        />
      ) : (
        <>
          <View style={styles.statRow}>
            <StatCard
              label="All predictions recorded"
              value={String(totalPredictions)}
              caption="Includes superseded rows"
              testID="stat-total-predictions"
            />
            <StatCard
              label="Current predictions"
              value={String(rows.length)}
              caption={
                predictedMatches === 1
                  ? "1 match, latest markets"
                  : `${predictedMatches} matches, latest markets`
              }
              testID="stat-predicted-matches"
            />
          </View>

          <View style={styles.statRow}>
            <StatCard
              label="Model versions"
              value={String(model?.model_versions.length ?? 0)}
              caption="Currently in use"
              testID="stat-model-versions"
            />
            <StatCard
              label="Latest prediction"
              value={formatRelative(model?.latest_generated_at ?? null)}
              caption="Most recent generation"
              tone="neutral"
              testID="stat-latest"
            />
          </View>

          <SectionHeader title="Current predictions by market" />
          <Card
            style={[
              styles.card,
              {
                backgroundColor: theme.colors.surface,
                borderColor: theme.colors.outline,
                borderRadius: theme.radius.card,
              },
            ]}
          >
            <Card.Content style={styles.rows}>
              {distribution.length === 0 ? (
                <Text
                  variant="bodyMedium"
                  style={{ color: theme.app.textMuted }}
                >
                  No market-level data available.
                </Text>
              ) : (
                distribution.map((entry) => (
                  <View key={entry.market} style={styles.barRow}>
                    <Text
                      variant="bodyMedium"
                      style={[
                        styles.barLabel,
                        { color: theme.colors.onSurface },
                      ]}
                      numberOfLines={1}
                    >
                      {MARKET_META[entry.market]?.label ?? entry.market}
                    </Text>
                    <View
                      style={[
                        styles.track,
                        { backgroundColor: theme.colors.surfaceVariant },
                      ]}
                    >
                      <View
                        style={[
                          styles.fill,
                          {
                            backgroundColor: theme.colors.primary,
                            // Proportional to the largest count, so the bar
                            // shows relative share; the number is authoritative.
                            width: `${maxMarketCount === 0 ? 0 : (entry.count / maxMarketCount) * 100}%`,
                          },
                        ]}
                      />
                    </View>
                    <Text
                      variant="labelMedium"
                      style={[
                        styles.barValue,
                        { color: theme.colors.onSurface },
                      ]}
                    >
                      {entry.count}
                    </Text>
                  </View>
                ))
              )}
            </Card.Content>
          </Card>

          <SectionHeader title="Model versions" />
          {model?.model_versions.length === 0 ? (
            <Text variant="bodyMedium" style={{ color: theme.app.textMuted }}>
              No model versions recorded.
            </Text>
          ) : (
            model?.model_versions.map((version) => (
              <Card
                key={version.model_version}
                style={[
                  styles.card,
                  {
                    backgroundColor: theme.colors.surface,
                    borderColor: theme.colors.outline,
                    borderRadius: theme.radius.card,
                  },
                ]}
                testID={`version-${version.model_version}`}
              >
                <Card.Content>
                  <View style={styles.versionHeader}>
                    <Text
                      variant="titleSmall"
                      style={{ color: theme.colors.onSurface }}
                    >
                      Model {version.model_version}
                    </Text>
                    <Text
                      variant="labelMedium"
                      style={{ color: theme.app.textMuted }}
                    >
                      {version.prediction_count} predictions
                    </Text>
                  </View>
                  <Text
                    variant="bodySmall"
                    style={{ color: theme.colors.onSurfaceVariant }}
                  >
                    First seen {formatRelative(version.first_generated_at)} ·
                    latest {formatRelative(version.latest_generated_at)}
                  </Text>
                </Card.Content>
              </Card>
            ))
          )}
        </>
      )}

      <Divider style={styles.divider} />

      {/* The honest absence. This is the screen's most important disclosure. */}
      <Card
        style={[
          styles.card,
          {
            backgroundColor: theme.app.backgroundSecondary,
            borderColor: theme.colors.outline,
            borderRadius: theme.radius.card,
          },
        ]}
        testID="evaluation-unavailable"
      >
        <Card.Content>
          <Text variant="titleSmall" style={{ color: theme.colors.onSurface }}>
            Historical evaluation not yet available
          </Text>
          <Text
            variant="bodySmall"
            style={[
              styles.noticeBody,
              { color: theme.colors.onSurfaceVariant },
            ]}
          >
            Accuracy, hit rate, Brier score, log loss, calibration and
            profitability are not exposed by the current API. The figures above
            describe prediction activity only — they are not a measure of
            forecast quality, and should not be read as such.
          </Text>
        </Card.Content>
      </Card>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  content: {
    padding: layout.screenPadding,
    paddingBottom: layout.listBottomInset,
  },
  statRow: {
    flexDirection: "row",
    gap: 12,
    marginBottom: 12,
  },
  card: {
    marginBottom: 10,
    borderWidth: 1,
  },
  rows: {
    gap: 10,
  },
  barRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
  },
  barLabel: {
    width: 150,
  },
  track: {
    flex: 1,
    height: 8,
    borderRadius: 4,
    overflow: "hidden",
  },
  fill: {
    height: "100%",
    borderRadius: 4,
  },
  barValue: {
    width: 36,
    textAlign: "right",
  },
  versionHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginBottom: 4,
  },
  divider: {
    marginVertical: 16,
  },
  noticeBody: {
    marginTop: 8,
    lineHeight: 18,
  },
});
