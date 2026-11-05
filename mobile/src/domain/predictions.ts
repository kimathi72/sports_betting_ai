/**
 * Market rules that the mobile app owns.
 *
 * The backend is authoritative for every market it returns, so this module does
 * NOT recompute 1X2, Over/Under or BTTS. It exists for three reasons:
 *
 *   1. Presentation: turning `H`/`over`/`1x` into text a user understands.
 *   2. Double chance derivation, for when the backend has 1X2 but no double
 *      chance row. The rule is fixed: 1X = H+D, X2 = D+A, 12 = H+A. Double
 *      chance is never a separate model.
 *   3. Neutralising the legacy 1X2-only fields on non-1X2 rows (see
 *      `types/api.ts`), by only ever reading `probabilities` + `selection`.
 */
import type {
  MarketName,
  MarketPrediction,
  PredictResponse,
  Probabilities,
} from "@/types/api";

export interface MarketMeta {
  label: string;
  outcomes: readonly string[];
}

/** Canonical outcome order per market, mirrored from docs/api-contracts.md. */
export const MARKET_META: Record<MarketName, MarketMeta> = {
  "1x2": { label: "Match Result (1X2)", outcomes: ["H", "D", "A"] },
  "over_under_2.5": {
    label: "Total Goals (Over/Under 2.5)",
    outcomes: ["over", "under"],
  },
  btts: { label: "Both Teams to Score", outcomes: ["yes", "no"] },
  double_chance: { label: "Double Chance", outcomes: ["1x", "x2", "12"] },
};

/** Display order for the market cards on the match screen. */
export const MARKET_ORDER: readonly MarketName[] = [
  "1x2",
  "over_under_2.5",
  "btts",
  "double_chance",
];

const OUTCOME_LABELS: Record<string, string> = {
  H: "Home",
  D: "Draw",
  A: "Away",
  over: "Over 2.5",
  under: "Under 2.5",
  yes: "Yes",
  no: "No",
  "1x": "Home or Draw",
  x2: "Draw or Away",
  "12": "Home or Away",
};

const MARKET_LABELS = new Set<string>(Object.keys(MARKET_META));

export function isSupportedMarket(value: string): value is MarketName {
  return MARKET_LABELS.has(value);
}

/** Human label for a single outcome of a market. */
export function formatMarketOutcome(
  market: MarketName,
  outcome: string,
): string {
  const label = OUTCOME_LABELS[outcome];
  if (label) {
    return label;
  }
  // Unknown key: show it verbatim rather than hiding a market the backend added.
  return `${market} · ${outcome}`;
}

/**
 * The distribution as ordered `[key, probability]` pairs.
 *
 * Unknown keys are dropped: rendering a key the market does not define would
 * present a value the backend never intended for this market. A missing
 * distribution yields an empty list, never an invented one.
 */
export function marketEntries(
  market: MarketName,
  probabilities: Probabilities | undefined | null,
): Array<[string, number]> {
  if (!probabilities) {
    return [];
  }

  return MARKET_META[market].outcomes
    .filter((key) => typeof probabilities[key] === "number")
    .map((key) => [key, probabilities[key]] as [string, number]);
}

/** The most likely outcome, or null when there is nothing to compare. */
export function selectionForProbabilities(
  probabilities: Probabilities | undefined | null,
): string | null {
  if (!probabilities) {
    return null;
  }

  let best: string | null = null;
  let bestValue = Number.NEGATIVE_INFINITY;

  for (const [key, value] of Object.entries(probabilities)) {
    if (typeof value === "number" && value > bestValue) {
      best = key;
      bestValue = value;
    }
  }

  return best;
}

/**
 * Double chance from 1X2. Returns null when 1X2 is incomplete, so the caller
 * shows "not available" instead of a fabricated distribution.
 */
export function deriveDoubleChance(
  oneXTwo: Probabilities | undefined | null,
): MarketPrediction | null {
  if (
    !oneXTwo ||
    typeof oneXTwo.H !== "number" ||
    typeof oneXTwo.D !== "number" ||
    typeof oneXTwo.A !== "number"
  ) {
    return null;
  }

  const probabilities: Probabilities = {
    "1x": oneXTwo.H + oneXTwo.D,
    x2: oneXTwo.D + oneXTwo.A,
    "12": oneXTwo.H + oneXTwo.A,
  };

  return {
    market: "double_chance",
    selection: selectionForProbabilities(probabilities) ?? "1x",
    probabilities,
    model_version: "derived",
    generated_at: new Date().toISOString(),
    derived: true,
  };
}

export interface MergedPredictions {
  /** Every available market, keyed by name. */
  byMarket: Partial<Record<MarketName, MarketPrediction>>;
  /** Raw list, including any derived double chance. */
  predictions: MarketPrediction[];
  /** Per-market failure messages from the backend. */
  errors: Record<string, string>;
  /** True when at least one requested market failed. */
  partial: boolean;
}

/**
 * Normalises a `POST` response for the UI.
 *
 * Double chance is filled in from 1X2 only when the backend did not return one,
 * and NEVER when the response contains no 1X2 (deriving it from btts or O/U
 * would be meaningless). The backend's own double chance always wins.
 */
export function mergePartialPredictionResponse(
  response: PredictResponse,
): MergedPredictions {
  const byMarket: Partial<Record<MarketName, MarketPrediction>> = {};

  for (const prediction of response.predictions) {
    if (isSupportedMarket(prediction.market)) {
      byMarket[prediction.market] = prediction;
    }
  }

  const missingDoubleChance = byMarket.double_chance === undefined;
  const oneXTwo = byMarket["1x2"];

  if (missingDoubleChance && oneXTwo) {
    const derived = deriveDoubleChance(oneXTwo.probabilities);
    if (derived) {
      byMarket.double_chance = {
        ...derived,
        model_version: oneXTwo.model_version,
      };
    }
  }

  const predictions = MARKET_ORDER.map((market) => byMarket[market]).filter(
    (prediction): prediction is MarketPrediction => prediction !== undefined,
  );

  return {
    byMarket,
    predictions,
    errors: response.errors ?? {},
    partial: Object.keys(response.errors ?? {}).length > 0,
  };
}

/** Formats a probability for display, e.g. 0.63552 -> "63.6%". */
export function formatProbability(value: number): string {
  return `${(value * 100).toFixed(1)}%`;
}
