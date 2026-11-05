/**
 * The three non-happy states, rendered one way everywhere.
 *
 * Centralising this is what stops each screen from inventing its own spinner
 * copy or — worse — silently rendering nothing when a query fails.
 */
import { StyleSheet, View } from "react-native";
import { ActivityIndicator, Button, Text } from "react-native-paper";

import { normalizeApiError } from "@/services/api/errors";

interface LoadingStateProps {
  message?: string;
}

export function LoadingState({ message = "Loading…" }: LoadingStateProps) {
  return (
    <View
      style={styles.centered}
      accessibilityRole="progressbar"
      accessibilityLabel={message}
    >
      <ActivityIndicator size="large" />
      <Text variant="bodyMedium" style={styles.spaced}>
        {message}
      </Text>
    </View>
  );
}

interface EmptyStateProps {
  title: string;
  message?: string;
  icon?: string;
}

export function EmptyState({ title, message }: EmptyStateProps) {
  return (
    <View style={styles.centered}>
      <Text variant="titleMedium" style={styles.spaced}>
        {title}
      </Text>
      {message ? (
        <Text variant="bodyMedium" style={[styles.spaced, styles.muted]}>
          {message}
        </Text>
      ) : null}
    </View>
  );
}

interface ErrorStateProps {
  error: unknown;
  onRetry?: () => void;
}

/**
 * Shows the backend's own message and offers a retry only when retrying can
 * help. A "Try again" button on a 400 is a promise the app cannot keep.
 */
export function ErrorState({ error, onRetry }: ErrorStateProps) {
  const normalized = normalizeApiError(error);

  return (
    <View style={styles.centered}>
      <Text variant="titleMedium" style={styles.spaced}>
        Something went wrong
      </Text>
      <Text
        variant="bodyMedium"
        style={[styles.spaced, styles.muted, styles.centeredText]}
      >
        {normalized.message}
      </Text>
      {onRetry && normalized.isRetryable ? (
        <Button
          mode="outlined"
          onPress={onRetry}
          style={styles.spaced}
          accessibilityLabel="Retry"
        >
          Try again
        </Button>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  centered: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    padding: 24,
  },
  centeredText: {
    textAlign: "center",
  },
  spaced: {
    marginTop: 12,
  },
  muted: {
    opacity: 0.75,
  },
});
