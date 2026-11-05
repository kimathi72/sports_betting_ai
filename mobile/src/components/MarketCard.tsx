/**
 * One market and its distribution.
 *
 * This component is the only place a market's numbers reach the screen, so it is
 * where the legacy-field rule (AD-7) is enforced: it reads `probabilities` and
 * `selection` and nothing else.
 */
import { StyleSheet, View } from "react-native";
import { Card, Chip, Divider, Text } from "react-native-paper";

import { ProbabilityBar } from "@/components/ProbabilityBar";
import {
  formatMarketOutcome,
  marketEntries,
  MARKET_META,
} from "@/domain/predictions";
import type { MarketName, MarketPrediction } from "@/types/api";

interface MarketCardProps {
  prediction: MarketPrediction;
}

export function MarketCard({ prediction }: MarketCardProps) {
  const meta = MARKET_META[prediction.market];
  const entries = marketEntries(prediction.market, prediction.probabilities);
  const title = meta?.label ?? prediction.market;

  return (
    <Card style={styles.card} testID={`market-${prediction.market}`}>
      <Card.Content>
        <View style={styles.header}>
          <Text variant="titleMedium">{title}</Text>
          {prediction.derived ? (
            <Chip compact icon="calculator-variant" testID="derived-badge">
              Derived
            </Chip>
          ) : null}
        </View>

        {entries.length === 0 ? (
          <Text variant="bodyMedium" style={styles.empty}>
            No probabilities returned for this market.
          </Text>
        ) : (
          entries.map(([outcome, value]) => (
            <ProbabilityBar
              key={outcome}
              label={formatMarketOutcome(prediction.market, outcome)}
              probability={value}
              highlighted={outcome === prediction.selection}
            />
          ))
        )}

        <Divider style={styles.divider} />
        <View style={styles.footer}>
          <Text variant="bodySmall">
            Most likely:{" "}
            {formatMarketOutcome(prediction.market, prediction.selection)}
          </Text>
          <Text variant="bodySmall">
            {prediction.derived
              ? "model "
              : `model ${prediction.model_version}`}
            {prediction.derived && prediction.selection
              ? `${prediction.model_version} (1X2)`
              : ""}
          </Text>
        </View>
      </Card.Content>
    </Card>
  );
}

/**
 * Fallback card for a market the user asked for but which failed or did not
 * arrive. Showing the market with an explanation is better than silently
 * omitting it, which reads as "this match has no BTTS prediction".
 */
export function MarketErrorCard({
  market,
  message,
}: {
  market: MarketName;
  message: string;
}) {
  const title = MARKET_META[market]?.label ?? market;

  return (
    <Card style={styles.card} testID={`market-error-${market}`}>
      <Card.Content>
        <Text variant="titleMedium">{title}</Text>
        <Text variant="bodyMedium" style={styles.empty}>
          Unavailable: {message}
        </Text>
      </Card.Content>
    </Card>
  );
}

/** A market that is supported but has no prediction yet. */
export function MarketPlaceholderCard({ market }: { market: MarketName }) {
  const title = MARKET_META[market]?.label ?? market;

  return (
    <Card style={styles.card} testID={`market-placeholder-${market}`}>
      <Card.Content>
        <Text variant="titleMedium">{title}</Text>
        <Text variant="bodyMedium" style={styles.empty}>
          No prediction for this market yet.
        </Text>
      </Card.Content>
    </Card>
  );
}

const styles = StyleSheet.create({
  card: {
    marginBottom: 12,
  },
  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginBottom: 8,
  },
  divider: {
    marginTop: 8,
    marginBottom: 8,
  },
  footer: {
    flexDirection: "row",
    justifyContent: "space-between",
    flexWrap: "wrap",
  },
  empty: {
    opacity: 0.75,
    marginTop: 4,
  },
});
