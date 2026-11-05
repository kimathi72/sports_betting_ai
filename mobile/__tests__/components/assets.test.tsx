/**
 * Team crest, competition logo and country flag behaviour.
 *
 * These components decide what a user sees for EVERY club in the dataset, so the
 * tests cover the two cases that actually break in production: a team with a
 * verified crest, and a team with none. The second is the common case here — ESPN
 * publishes top-division squads only — and the requirement is that it degrades to an
 * honest monogram rather than another club's badge, an emoji, or a broken image.
 */
import { render, fireEvent } from "@testing-library/react-native";

import {
  CompetitionLogo,
  competitionInitials,
} from "@/components/CompetitionLogo";
import { CountryFlag } from "@/components/CountryFlag";
import { TeamCrest, crestInitials } from "@/components/TeamCrest";
import { crestForTeam, TEAM_CRESTS } from "@/assets/teamCrests";
import { logoForCompetition } from "@/assets/competitionLogos";
import { flagForCountry } from "@/assets/flags";

describe("crest map", () => {
  it("resolves a verified club", () => {
    expect(crestForTeam("Arsenal")).toMatch(/^https:\/\//);
  });

  it("resolves a club whose canonical name differs in case", () => {
    expect(crestForTeam("arsenal")).toBe(crestForTeam("Arsenal"));
  });

  it("returns null rather than guessing for an unknown club", () => {
    expect(crestForTeam("A Club That Does Not Exist")).toBeNull();
  });

  it("returns null for a missing name instead of throwing", () => {
    expect(crestForTeam(null)).toBeNull();
    expect(crestForTeam(undefined)).toBeNull();
    expect(crestForTeam("")).toBeNull();
  });

  it("holds only absolute https URLs", () => {
    for (const [name, url] of Object.entries(TEAM_CRESTS)) {
      expect(url).toMatch(/^https:\/\//);
      expect(name.length).toBeGreaterThan(0);
    }
  });
});

// `render` is asynchronous in @testing-library/react-native 14 and must be
// awaited before querying, otherwise the returned value is still a Promise and
// neither the types nor the queries line up.
describe("TeamCrest", () => {
  it("renders the image when a verified crest exists", async () => {
    const { getByTestId } = await render(<TeamCrest name="Arsenal" />);
    expect(getByTestId("team-crest-Arsenal")).toBeTruthy();
  });

  it("renders an initials monogram when no crest is verified", async () => {
    const { getByTestId, queryByTestId } = await render(
      <TeamCrest name="Accrington Stanley" />,
    );
    expect(getByTestId("team-crest-fallback-Accrington Stanley")).toBeTruthy();
    expect(queryByTestId("team-crest-Accrington Stanley")).toBeNull();
  });

  it("falls back to the monogram when the image fails to load", async () => {
    const { getByTestId, queryByTestId } = await render(
      <TeamCrest name="Arsenal" />,
    );
    // `fireEvent` is asynchronous in RNTL 14: it awaits the state update, so the
    // assertion below only sees the fallback if the call is awaited.
    await fireEvent(getByTestId("team-crest-Arsenal"), "error");
    expect(getByTestId("team-crest-fallback-Arsenal")).toBeTruthy();
    expect(queryByTestId("team-crest-Arsenal")).toBeNull();
  });

  it("labels the fallback so a screen reader reports the team", async () => {
    const { getByLabelText } = await render(
      <TeamCrest name="Accrington Stanley" />,
    );
    expect(getByLabelText(/Accrington Stanley/)).toBeTruthy();
  });
});

describe("crestInitials", () => {
  it("takes the first letters of two words", () => {
    expect(crestInitials("Aston Villa")).toBe("AV");
  });

  it("uses two letters for a single-word club", () => {
    expect(crestInitials("Arsenal")).toBe("AR");
  });

  it("ignores club-type words when choosing initials", () => {
    expect(crestInitials("FC Barcelona")).toBe("BA");
    expect(crestInitials("AC Milan")).toBe("MI");
  });

  it("never returns an empty string", () => {
    expect(crestInitials("")).toBeTruthy();
    expect(crestInitials("FC")).toBeTruthy();
  });
});

describe("competition logos and flags", () => {
  it("resolves a catalogue code to a verified logo", () => {
    expect(logoForCompetition("E0")).toMatch(/^https:\/\//);
  });

  it("returns null for a code it does not know", () => {
    expect(logoForCompetition("ZZ9")).toBeNull();
    expect(logoForCompetition(null)).toBeNull();
  });

  it("resolves the England flag to the sub-national flag, not the Union Jack", () => {
    expect(flagForCountry("England")).toContain("gb-eng");
    expect(flagForCountry("Scotland")).toContain("gb-sct");
  });

  it("returns null for an unknown country", () => {
    expect(flagForCountry("Atlantis")).toBeNull();
  });

  it("renders a competition monogram for a competition without a logo", async () => {
    const { getByTestId } = await render(
      <CompetitionLogo code="ZZ9" name="Serie B" />,
    );
    expect(getByTestId("competition-logo-fallback-ZZ9")).toBeTruthy();
  });

  it("renders a neutral placeholder for a country without a flag", async () => {
    const { getByTestId } = await render(<CountryFlag country="Atlantis" />);
    expect(getByTestId("country-flag-fallback")).toBeTruthy();
  });

  it("uses sensible initials for a multi-word competition", () => {
    expect(competitionInitials("UEFA Champions League")).toBe("UC");
  });
});
