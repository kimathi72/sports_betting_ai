/**
 * Settings — service health summary, app information and preferences.
 *
 * Per the approved decision, System Status lives here as a nested route
 * (`/settings/system`). This screen shows a compact health summary so the state
 * is visible without navigating, and links to the full verified screen rather
 * than duplicating its queries.
 */
import { ScrollView, StyleSheet, View } from "react-native";
import { useRouter } from "expo-router";
import { Card, Divider, List, Text } from "react-native-paper";

import { ErrorState, LoadingState } from "@/components/ScreenState";
import { SectionHeader } from "@/components/SectionHeader";
import { useHealth, useModelStatus, useSyncStatus } from "@/hooks/useApi";
import { useAppTheme } from "@/theme/useAppTheme";
import { formatRelative } from "@/utils/format";
import { config } from "@/config/environment";
import { layout } from "@/theme/theme";

export default function SettingsScreen() {
  const theme = useAppTheme();
  const router = useRouter();

  const syncQuery = useSyncStatus();
  const modelQuery = useModelStatus();
  const healthQuery = useHealth();

  if (syncQuery.isLoading || healthQuery.isLoading) {
    return <LoadingState message="Loading settings…" />;
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
  const apiReachable = healthQuery.isSuccess;

  return (
    <ScrollView
      style={{ backgroundColor: theme.colors.background }}
      contentContainerStyle={styles.content}
    >
      <SectionHeader title="System health" />

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
        <Card.Content style={styles.statusRows}>
          <View style={styles.statusRow}>
            <Text
              variant="bodyMedium"
              style={{ color: theme.colors.onSurface }}
            >
              API
            </Text>
            <Text
              variant="labelMedium"
              style={{
                color: apiReachable ? theme.app.success : theme.app.danger,
              }}
              testID="health-api"
            >
              {apiReachable ? "Reachable" : "Unreachable"}
            </Text>
          </View>

          <View style={styles.statusRow}>
            <Text
              variant="bodyMedium"
              style={{ color: theme.colors.onSurface }}
            >
              Data synchronization
            </Text>
            <Text
              variant="labelMedium"
              style={{
                color:
                  sync?.status === "ok" ? theme.app.success : theme.app.warning,
              }}
              testID="health-sync"
            >
              {sync?.status === "ok" ? "Up to date" : "Needs attention"}
            </Text>
          </View>

          <View style={styles.statusRow}>
            <Text
              variant="bodyMedium"
              style={{ color: theme.colors.onSurface }}
            >
              Last fixture sync
            </Text>
            <Text variant="labelMedium" style={{ color: theme.app.textMuted }}>
              {formatRelative(sync?.schedules.fixtures.last_success_at ?? null)}
            </Text>
          </View>

          <View style={styles.statusRow}>
            <Text
              variant="bodyMedium"
              style={{ color: theme.colors.onSurface }}
            >
              Last result sync
            </Text>
            <Text variant="labelMedium" style={{ color: theme.app.textMuted }}>
              {formatRelative(sync?.schedules.results.last_success_at ?? null)}
            </Text>
          </View>
        </Card.Content>
      </Card>

      <List.Item
        title="System status"
        description="Synchronization detail and model versions"
        left={(props) => <List.Icon {...props} icon="heart-pulse" />}
        right={(props) => <List.Icon {...props} icon="chevron-right" />}
        onPress={() => router.push("/settings/system")}
        accessibilityLabel="Open system status"
        style={[
          styles.listItem,
          {
            backgroundColor: theme.colors.surface,
            borderRadius: theme.radius.card,
            borderColor: theme.colors.outline,
            borderWidth: 1,
          },
        ]}
        titleStyle={{ color: theme.colors.onSurface }}
        descriptionStyle={{ color: theme.app.textMuted }}
        testID="open-system-status"
      />

      <Divider style={styles.divider} />

      <SectionHeader title="Application" />
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
        <Card.Content style={styles.statusRows}>
          <View style={styles.statusRow}>
            <Text
              variant="bodyMedium"
              style={{ color: theme.colors.onSurface }}
            >
              Version
            </Text>
            <Text variant="labelMedium" style={{ color: theme.app.textMuted }}>
              {config.appVersion}
            </Text>
          </View>
          <View style={styles.statusRow}>
            <Text
              variant="bodyMedium"
              style={{ color: theme.colors.onSurface }}
            >
              Environment
            </Text>
            <Text variant="labelMedium" style={{ color: theme.app.textMuted }}>
              {config.appEnv}
            </Text>
          </View>
          <View style={styles.statusRow}>
            <Text
              variant="bodyMedium"
              style={{ color: theme.colors.onSurface }}
            >
              Models in use
            </Text>
            <Text variant="labelMedium" style={{ color: theme.app.textMuted }}>
              {modelQuery.data?.model_versions.length ?? 0}
            </Text>
          </View>
        </Card.Content>
      </Card>

      <Text
        variant="bodySmall"
        style={[styles.footnote, { color: theme.app.textMuted }]}
      >
        Preferences are not yet implemented. This section will hold theme,
        notification and data-refresh options.
      </Text>
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
    borderWidth: 1,
  },
  statusRows: {
    gap: 12,
  },
  statusRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    minHeight: 24,
  },
  listItem: {
    marginBottom: 12,
  },
  divider: {
    marginVertical: 8,
  },
  footnote: {
    marginTop: 8,
    lineHeight: 18,
  },
});
