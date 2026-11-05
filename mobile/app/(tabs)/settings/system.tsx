/**
 * Operational status — model versions and daily synchronization health.
 *
 * Both endpoints are read-only and cheap to poll. A "degraded" synchronization
 * is shown as a freshness warning, NOT as an error (per the API contract): the
 * API is still serving data, it may just be a day old.
 */
import { ScrollView, StyleSheet, View } from "react-native";
import { Card, Chip, Divider, Text } from "react-native-paper";

import { useAppTheme } from "@/theme/useAppTheme";
import type { AppTheme } from "@/theme/theme";

import { EmptyState, ErrorState, LoadingState } from "@/components/ScreenState";
import { useModelStatus, useSyncStatus } from "@/hooks/useApi";
import { formatDate, formatRelative } from "@/utils/format";
import { layout } from "@/theme/theme";
import type { SyncSchedule } from "@/types/api";

function SyncCard({
  title,
  schedule,
  theme,
}: {
  title: string;
  schedule: SyncSchedule;
  theme: AppTheme;
}) {
  const attempt = schedule.last_attempt;

  return (
    <Card style={styles.card} testID={`sync-card-${title.toLowerCase()}`}>
      <Card.Content>
        <View style={styles.rowBetween}>
          <Text variant="titleSmall">{title}</Text>
          <Chip
            compact
            mode="outlined"
            icon={schedule.stale ? "alert-outline" : "check-circle-outline"}
            // Same reason as the Predictions filter chips: Paper's default chip
            // container colour is off-palette on this theme.
            style={{ backgroundColor: theme.colors.surface, borderColor: theme.colors.outline }}
            textStyle={{ color: schedule.stale ? theme.app.warning : theme.app.success }}
          >
            {schedule.stale ? "Stale" : "Fresh"}
          </Chip>
        </View>

        <Text variant="bodySmall" style={styles.line}>
          Last success: {formatRelative(schedule.last_success_at)}
        </Text>
        <Text variant="bodySmall" style={styles.line}>
          Last attempt: {formatRelative(schedule.last_attempt_at)}
          {attempt ? ` (${attempt.status}, ${attempt.trigger})` : ""}
        </Text>

        {attempt ? (
          <Text variant="bodySmall" style={styles.line}>
            Processed {attempt.counts.fetched} · created{" "}
            {attempt.counts.created} · updated {attempt.counts.updated} ·
            skipped {attempt.counts.skipped} · rejected{" "}
            {attempt.counts.rejected}
          </Text>
        ) : null}

        {attempt?.error ? (
          <Text variant="bodySmall" style={[styles.errorText, { color: theme.app.danger }]}>
            {attempt.error}
          </Text>
        ) : null}

        {schedule.schedule ? (
          <Text variant="bodySmall" style={styles.muted}>
            Next run: {formatDate(schedule.schedule.next_run_at)} ·{" "}
            {schedule.schedule.cron} {schedule.schedule.timezone}
          </Text>
        ) : null}
      </Card.Content>
    </Card>
  );
}

export default function SystemStatusScreen() {
  const theme = useAppTheme();
  const syncQuery = useSyncStatus();
  const modelQuery = useModelStatus();

  if (syncQuery.isLoading || modelQuery.isLoading) {
    return <LoadingState message="Checking services…" />;
  }

  if (syncQuery.error) {
    return (
      <ErrorState
        error={syncQuery.error}
        onRetry={() => {
          void syncQuery.refetch();
        }}
      />
    );
  }

  const sync = syncQuery.data;
  const model = modelQuery.data;

  return (
    <ScrollView contentContainerStyle={styles.content}>
      <Card style={styles.card}>
        <Card.Content>
          <Text variant="labelMedium">Data synchronization</Text>
          <Text variant="headlineSmall" testID="sync-overall">
            {sync?.status === "ok" ? "Up to date" : "Needs attention"}
          </Text>
          <Text variant="bodySmall" style={styles.muted}>
            Checked {formatRelative(sync?.checked_at ?? null)}
          </Text>
        </Card.Content>
      </Card>

      {sync ? (
        <>
          <SyncCard title="Fixtures" schedule={sync.schedules.fixtures} theme={theme} />
          <SyncCard title="Results" schedule={sync.schedules.results} theme={theme} />
        </>
      ) : null}

      <Divider style={styles.divider} />

      <Text variant="titleMedium" style={styles.sectionTitle}>
        Prediction models
      </Text>

      {modelQuery.error ? (
        <ErrorState
          error={modelQuery.error}
          onRetry={() => {
            void modelQuery.refetch();
          }}
        />
      ) : model && model.model_versions.length === 0 ? (
        <EmptyState
          title="No predictions stored"
          message="Model versions appear here once a prediction has been generated."
        />
      ) : (
        model?.model_versions.map((version) => (
          <Card
            key={version.model_version}
            style={styles.card}
            testID={`model-${version.model_version}`}
          >
            <Card.Content>
              <Text variant="titleSmall">{version.model_version}</Text>
              <Text variant="bodySmall" style={styles.line}>
                {version.prediction_count} predictions
              </Text>
              <Text variant="bodySmall" style={styles.muted}>
                Latest: {formatRelative(version.latest_generated_at)}
              </Text>
            </Card.Content>
          </Card>
        ))
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  content: {
    padding: layout.screenPadding,
    paddingBottom: layout.listBottomInset,
  },
  card: {
    marginBottom: 12,
  },
  rowBetween: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
  },
  line: {
    marginTop: 4,
  },
  muted: {
    marginTop: 4,
    opacity: 0.7,
  },
  errorText: {
    marginTop: 6,

  },
  divider: {
    marginVertical: 16,
  },
  sectionTitle: {
    marginBottom: 8,
  },
});
