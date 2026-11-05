/**
 * Diagram-free aggregation of stored predictions for the Predictions screen.
 *
 * WHY THIS ISN'T IN THE SCREEN
 * ----------------------------
 * Grouping a flat prediction list into per-match cards is data shaping, and it
 * is the part most worth testing. Keeping it in a pure module means the rule
 * ("one card per match, newest market set wins") is provable without rendering.
 */
import type { MarketName, StoredPrediction } from "@/types/api";

/** Origin of a prediction, which the UI must show honestly. */
export type PredictionSource = "generated" | "derived";

export interface PredictedMatchGroup {
  matchId: number;
  /** Newest generation timestamp across the group's markets. */
  generatedAt: string;
  /** Distinct model versions that produced the markets in this group. */
  modelVersions: string[];
  markets: MarketName[];
  predictions: StoredPrediction[];
}

/**
 * Groups stored predictions by match.
 *
 * Rows arrive newest-first from the API. A match may legitimately hold several
 * markets; it must NOT hold two rows of the same market, but if it does the
 * newest wins, so a superseded prediction never appears alongside its
 * replacement.
 */
export function groupPredictionsByMatch(
  rows: readonly StoredPrediction[],
): PredictedMatchGroup[] {
  const byMatch = new Map<number, Map<MarketName, StoredPrediction>>();

  for (const row of rows) {
    const markets =
      byMatch.get(row.match_id) ?? new Map<MarketName, StoredPrediction>();
    if (!markets.has(row.market)) {
      markets.set(row.market, row);
    }
    byMatch.set(row.match_id, markets);
  }

  const groups: PredictedMatchGroup[] = [];

  for (const [matchId, markets] of byMatch) {
    const predictions = [...markets.values()];
    // ISO timestamps sort lexicographically, so this is correctly newest-first.
    // (Length-indexed rather than .at(), which the project lib target omits.)
    const sortedTimestamps = predictions
        .map((prediction) => prediction.generated_at)
        .sort();
    const generatedAt = sortedTimestamps[sortedTimestamps.length - 1] ?? "";
    const modelVersions = [
      ...new Set(predictions.map((row) => row.model_version)),
    ].sort();

    groups.push({
      matchId,
      generatedAt,
      modelVersions,
      markets: predictions.map((row) => row.market),
      predictions,
    });
  }

  return groups.sort((a, b) => b.generatedAt.localeCompare(a.generatedAt));
}

/**
 * Counts of stored predictions per market.
 *
 * This is a DISTRIBUTION OF PREDICTIONS, not a performance metric. It counts how
 * many rows exist per market — never how often a prediction was correct, which
 * the API cannot answer.
 */
export function marketDistribution(
  rows: readonly StoredPrediction[],
): Array<{ market: MarketName; count: number }> {
  const counts = new Map<MarketName, number>();
  for (const row of rows) {
    counts.set(row.market, (counts.get(row.market) ?? 0) + 1);
  }
  return [...counts.entries()]
    .map(([market, count]) => ({ market, count }))
    .sort((a, b) => b.count - a.count);
}
