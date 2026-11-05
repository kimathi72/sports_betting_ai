/**
 * Prediction domain rules.
 *
 * Two rules are easy to get wrong and produce plausible-looking wrong numbers:
 *
 *   1. NON-1X2 ROWS CARRY MEANINGLESS LEGACY FIELDS. A double-chance row from
 *      the backend reports `away_probability: 1.0` and
 *      `most_likely_outcome: "away"`. Rendering those for a double-chance card
 *      would show "Away" to a user looking at a 1X / X2 / 12 market. Only
 *      `probabilities` and `selection` are market-correct.
 *
 *   2. DOUBLE CHANCE IS DERIVED, never modelled:
 *      1X = P(H)+P(D),  X2 = P(D)+P(A),  12 = P(H)+P(A).
 */
import {
  MARKET_META,
  formatMarketOutcome,
  isSupportedMarket,
  marketEntries,
  selectionForProbabilities,
  deriveDoubleChance,
  mergePartialPredictionResponse,
} from "@/domain/predictions";
import type { MarketPrediction } from "@/types/api";

describe("market metadata", () => {
  it("defines the four supported markets with their canonical outcome keys", () => {
    expect(Object.keys(MARKET_META).sort()).toEqual([
      "1x2",
      "btts",
      "double_chance",
      "over_under_2.5",
    ]);
    expect(MARKET_META["1x2"].outcomes).toEqual(["H", "D", "A"]);
    expect(MARKET_META["over_under_2.5"].outcomes).toEqual(["over", "under"]);
    expect(MARKET_META.btts.outcomes).toEqual(["yes", "no"]);
    expect(MARKET_META.double_chance.outcomes).toEqual(["1x", "x2", "12"]);
  });

  it("recognises only the supported markets", () => {
    expect(isSupportedMarket("1x2")).toBe(true);
    expect(isSupportedMarket("corners")).toBe(false);
  });
});

describe("formatMarketOutcome", () => {
  it("labels 1X2 outcomes from the home team perspective", () => {
    expect(formatMarketOutcome("1x2", "H")).toBe("Home");
    expect(formatMarketOutcome("1x2", "D")).toBe("Draw");
    expect(formatMarketOutcome("1x2", "A")).toBe("Away");
  });

  it("labels the other markets in plain language", () => {
    expect(formatMarketOutcome("over_under_2.5", "over")).toBe("Over 2.5");
    expect(formatMarketOutcome("over_under_2.5", "under")).toBe("Under 2.5");
    expect(formatMarketOutcome("btts", "yes")).toBe("Yes");
    expect(formatMarketOutcome("btts", "no")).toBe("No");
    expect(formatMarketOutcome("double_chance", "1x")).toBe("Home or Draw");
    expect(formatMarketOutcome("double_chance", "x2")).toBe("Draw or Away");
    expect(formatMarketOutcome("double_chance", "12")).toBe("Home or Away");
  });
});

describe("marketEntries", () => {
  it("returns every outcome key present in the distribution, in canonical order", () => {
    const entries = marketEntries("1x2", { A: 0.2, H: 0.5, D: 0.3 });

    expect(entries.map(([key]) => key)).toEqual(["H", "D", "A"]);
    expect(entries[0][1]).toBe(0.5);
  });

  it("ignores unknown keys rather than inventing outcomes", () => {
    const entries = marketEntries("btts", { yes: 0.6, no: 0.4, maybe: 0.1 });

    expect(entries.map(([key]) => key)).toEqual(["yes", "no"]);
  });

  it("returns an empty list for a missing distribution", () => {
    expect(marketEntries("1x2", undefined)).toEqual([]);
  });
});

describe("selectionForProbabilities", () => {
  it("picks the highest-probability outcome", () => {
    expect(selectionForProbabilities({ H: 0.2, D: 0.3, A: 0.5 })).toBe("A");
  });

  it("returns null when there is nothing to compare", () => {
    expect(selectionForProbabilities({})).toBeNull();
    expect(selectionForProbabilities(null)).toBeNull();
  });
});

describe("deriveDoubleChance", () => {
  it("derives the three combinations from 1X2 exactly", () => {
    const dc = deriveDoubleChance({ H: 0.5, D: 0.3, A: 0.2 });

    expect(dc).not.toBeNull();
    expect(dc!.probabilities["1x"]).toBeCloseTo(0.8, 10);
    expect(dc!.probabilities.x2).toBeCloseTo(0.5, 10);
    expect(dc!.probabilities["12"]).toBeCloseTo(0.7, 10);
    // Each combination is the union of two disjoint outcomes, so the sum of the
    // three is exactly 2 (every outcome appears in exactly two of them).
    const total =
      dc!.probabilities["1x"] + dc!.probabilities.x2 + dc!.probabilities["12"];
    expect(total).toBeCloseTo(2, 10);
  });

  it("names the most likely combination", () => {
    const dc = deriveDoubleChance({ H: 0.63552, D: 0.27695, A: 0.08753 });

    expect(dc!.selection).toBe("1x");
    expect(dc!.probabilities["1x"]).toBeCloseTo(0.91247, 5);
  });

  it("returns null when 1X2 is unavailable, rather than guessing", () => {
    expect(deriveDoubleChance(null)).toBeNull();
    expect(deriveDoubleChance({ H: 0.5 })).toBeNull();
  });

  it("is flagged as derived so the UI can label it honestly", () => {
    expect(deriveDoubleChance({ H: 0.5, D: 0.3, A: 0.2 })!.derived).toBe(true);
  });
});

describe("mergePartialPredictionResponse", () => {
  const oneXTwo: MarketPrediction = {
    market: "1x2",
    selection: "H",
    probabilities: { H: 0.5, D: 0.3, A: 0.2 },
    model_version: "0.3.0",
    generated_at: "2026-10-30T08:38:24Z",
  };

  it("keeps successful markets when some failed", () => {
    const result = mergePartialPredictionResponse({
      match_id: 4280,
      predictions: [oneXTwo],
      errors: { btts: "ML service unreachable" },
    });

    expect(result.partial).toBe(true);
    // The successful 1x2 is kept, and double chance is derived from it; the
    // failed btts market does not appear.
    expect(result.byMarket["1x2"]).toBeDefined();
    expect(result.byMarket.btts).toBeUndefined();
    expect(result.errors.btts).toBe("ML service unreachable");
  });

  it("is not partial when every market succeeded", () => {
    const result = mergePartialPredictionResponse({
      match_id: 4280,
      predictions: [oneXTwo],
      errors: {},
    });

    expect(result.partial).toBe(false);
  });

  it("derives double chance when the backend did not supply it", () => {
    const result = mergePartialPredictionResponse({
      match_id: 4280,
      predictions: [oneXTwo],
      errors: {},
    });

    const dc = result.byMarket.double_chance;
    expect(dc).toBeDefined();
    expect(dc!.probabilities["1x"]).toBeCloseTo(0.8, 10);
  });

  it("prefers the backend double chance when it did supply one", () => {
    const backendDc: MarketPrediction = {
      market: "double_chance",
      selection: "1x",
      probabilities: { "1x": 0.9, x2: 0.4, "12": 0.7 },
      model_version: "0.3.0",
      generated_at: "2026-10-30T08:38:24Z",
    };
    const result = mergePartialPredictionResponse({
      match_id: 4280,
      predictions: [oneXTwo, backendDc],
      errors: {},
    });

    expect(result.byMarket.double_chance!.probabilities["1x"]).toBe(0.9);
    expect(result.byMarket.double_chance!.derived).toBeUndefined();
  });

  it("never derives double chance from a non-1X2 market", () => {
    const btts: MarketPrediction = {
      market: "btts",
      selection: "yes",
      probabilities: { yes: 0.6, no: 0.4 },
      model_version: "0.4.0",
      generated_at: "2026-10-30T08:38:24Z",
    };
    const result = mergePartialPredictionResponse({
      match_id: 4280,
      predictions: [btts],
      errors: {},
    });

    expect(result.byMarket.double_chance).toBeUndefined();
  });
});
