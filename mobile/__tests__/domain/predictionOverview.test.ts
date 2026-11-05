/**
 * Aggregation of stored predictions.
 *
 * The rule that matters: a match with several markets is ONE entry, and a
 * superseded row of the same market never appears next to its replacement.
 */
import {
  groupPredictionsByMatch,
  marketDistribution,
} from "@/hooks/usePredictionOverview";
import type { StoredPrediction } from "@/types/api";

function row(
  id: number,
  matchId: number,
  market: StoredPrediction["market"],
  generatedAt: string,
  modelVersion = "0.3.0",
): StoredPrediction {
  return {
    id,
    match_id: matchId,
    market,
    model_version: modelVersion,
    home_probability: 0,
    draw_probability: 0,
    away_probability: 0,
    probabilities: {},
    selection: "",
    most_likely_outcome: "",
    generated_at: generatedAt,
  };
}

describe("groupPredictionsByMatch", () => {
  it("returns one group per match", () => {
    const groups = groupPredictionsByMatch([
      row(1, 4280, "1x2", "2026-10-30T08:00:00Z"),
      row(2, 4280, "btts", "2026-10-30T08:00:00Z"),
      row(3, 5000, "1x2", "2026-10-29T08:00:00Z"),
    ]);

    expect(groups).toHaveLength(2);
    expect(groups.find((group) => group.matchId === 4280)?.markets).toEqual([
      "1x2",
      "btts",
    ]);
  });

  it("keeps only the newest row when a market was regenerated", () => {
    const groups = groupPredictionsByMatch([
      row(2, 4280, "1x2", "2026-10-30T12:00:00Z"),
      row(1, 4280, "1x2", "2026-10-30T08:00:00Z"),
    ]);

    expect(groups[0]?.predictions).toHaveLength(1);
    expect(groups[0]?.predictions[0]?.id).toBe(2);
  });

  it("sorts groups newest first", () => {
    const groups = groupPredictionsByMatch([
      row(1, 1, "1x2", "2026-10-28T08:00:00Z"),
      row(2, 2, "1x2", "2026-10-30T08:00:00Z"),
    ]);

    expect(groups.map((group) => group.matchId)).toEqual([2, 1]);
  });

  it("collects the distinct model versions in a group", () => {
    const groups = groupPredictionsByMatch([
      row(1, 4280, "1x2", "2026-10-30T08:00:00Z", "0.3.0"),
      row(2, 4280, "btts", "2026-10-30T08:00:00Z", "0.4.0"),
      row(3, 4280, "over_under_2.5", "2026-10-30T08:00:00Z", "0.4.0"),
    ]);

    expect(groups[0]?.modelVersions).toEqual(["0.3.0", "0.4.0"]);
  });

  it("handles an empty list", () => {
    expect(groupPredictionsByMatch([])).toEqual([]);
  });
});

describe("marketDistribution", () => {
  it("counts rows per market", () => {
    const distribution = marketDistribution([
      row(1, 1, "1x2", ""),
      row(2, 2, "1x2", ""),
      row(3, 1, "btts", ""),
    ]);

    expect(distribution).toEqual([
      { market: "1x2", count: 2 },
      { market: "btts", count: 1 },
    ]);
  });

  it("is a count of predictions, not a performance measure", () => {
    // Guards against anyone renaming this into an accuracy statistic.
    expect(marketDistribution([])).toEqual([]);
  });
});
