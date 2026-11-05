/**
 * Market rendering.
 *
 * The regression this file exists to prevent: a backend double-chance row
 * carries `away_probability: 1.0` and `most_likely_outcome: "away"`. Rendering
 * those would tell a user that a "Home or Draw / Draw or Away / Home or Away"
 * market predicts Away. This component must render only `probabilities` and
 * `selection`.
 */
import { render, screen } from "@testing-library/react-native";
import { PaperProvider } from "react-native-paper";

import {
  MarketCard,
  MarketErrorCard,
  MarketPlaceholderCard,
} from "@/components/MarketCard";
import type { MarketPrediction } from "@/types/api";

async function renderCard(prediction: MarketPrediction) {
  return render(
    <PaperProvider>
      <MarketCard prediction={prediction} />
    </PaperProvider>,
  );
}

const oneXTwo: MarketPrediction = {
  market: "1x2",
  selection: "H",
  probabilities: { H: 0.63552, D: 0.27695, A: 0.08753 },
  model_version: "0.3.0",
  generated_at: "2026-10-30T08:38:24Z",
};

describe("MarketCard", () => {
  it("renders every 1X2 outcome with its probability", async () => {
    await renderCard(oneXTwo);

    expect(screen.getByText("Match Result (1X2)")).toBeTruthy();
    expect(screen.getByText("Home")).toBeTruthy();
    expect(screen.getByText("Draw")).toBeTruthy();
    expect(screen.getByText("Away")).toBeTruthy();
    expect(screen.getByText("63.6%")).toBeTruthy();
  });

  it("names the most likely outcome", async () => {
    await renderCard(oneXTwo);
    expect(screen.getByText(/Most likely: Home/)).toBeTruthy();
  });

  it("renders Over/Under 2.5 with its own outcome labels", async () => {
    await renderCard({
      market: "over_under_2.5",
      selection: "over",
      probabilities: { over: 0.87075, under: 0.12925 },
      model_version: "0.4.0",
      generated_at: "2026-10-30T08:38:24Z",
    });

    expect(screen.getByText("Over 2.5")).toBeTruthy();
    expect(screen.getByText("Under 2.5")).toBeTruthy();
    expect(screen.getByText("87.1%")).toBeTruthy();
  });

  it("renders BTTS with yes/no labels", async () => {
    await renderCard({
      market: "btts",
      selection: "yes",
      probabilities: { no: 0.37127, yes: 0.62873 },
      model_version: "0.4.0",
      generated_at: "2026-10-30T08:38:24Z",
    });

    expect(screen.getByText("Yes")).toBeTruthy();
    expect(screen.getByText("No")).toBeTruthy();
  });

  it("renders double chance from probabilities, never the legacy away field", async () => {
    await renderCard({
      market: "double_chance",
      selection: "1x",
      probabilities: { "1x": 0.91247, x2: 0.36448, "12": 0.72305 },
      model_version: "0.3.0",
      generated_at: "2026-10-30T08:38:24Z",
      // Deliberately misleading legacy values, as the backend really sends.
      ...({ away_probability: 1.0, most_likely_outcome: "away" } as object),
    });

    expect(screen.getByText("Home or Draw")).toBeTruthy();
    expect(screen.getByText(/Most likely: Home or Draw/)).toBeTruthy();
    // The trap: an "Away" label here would be the legacy field leaking through.
    expect(screen.queryByText(/Most likely: Away/)).toBeNull();
  });

  it("marks a derived double chance as derived", async () => {
    await renderCard({
      market: "double_chance",
      selection: "1x",
      probabilities: { "1x": 0.8, x2: 0.5, "12": 0.7 },
      model_version: "0.3.0",
      generated_at: "2026-10-30T08:38:24Z",
      derived: true,
    });

    expect(screen.getByTestId("derived-badge")).toBeTruthy();
  });

  it("does not mark a backend-supplied double chance as derived", async () => {
    await renderCard({
      market: "double_chance",
      selection: "1x",
      probabilities: { "1x": 0.8, x2: 0.5, "12": 0.7 },
      model_version: "0.3.0",
      generated_at: "2026-10-30T08:38:24Z",
    });

    expect(screen.queryByTestId("derived-badge")).toBeNull();
  });

  it("shows an explanation when a market has no probabilities", async () => {
    await renderCard({
      market: "btts",
      selection: "",
      probabilities: {},
      model_version: "0.4.0",
      generated_at: "2026-10-30T08:38:24Z",
    });

    expect(screen.getByText(/No probabilities returned/)).toBeTruthy();
  });
});

describe("MarketErrorCard", () => {
  it("shows the failure for a specific market instead of hiding it", async () => {
    await render(
      <PaperProvider>
        <MarketErrorCard market="btts" message="ML service unreachable" />
      </PaperProvider>,
    );

    expect(screen.getByText("Both Teams to Score")).toBeTruthy();
    expect(
      screen.getByText(/Unavailable: ML service unreachable/),
    ).toBeTruthy();
  });
});

describe("MarketPlaceholderCard", () => {
  it('distinguishes "not predicted yet" from "failed"', async () => {
    await render(
      <PaperProvider>
        <MarketPlaceholderCard market="1x2" />
      </PaperProvider>,
    );

    expect(screen.getByText(/No prediction for this market yet/)).toBeTruthy();
  });
});
