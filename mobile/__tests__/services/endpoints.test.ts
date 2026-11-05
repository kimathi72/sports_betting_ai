/**
 * Endpoint construction.
 *
 * Every path is defined once. These tests pin the two contract details that are
 * easiest to get wrong and that the backend cannot absorb:
 *
 *   1. `POST /api/v1/predictions` takes match_id in the BODY. There is no
 *      `POST /predictions/:id` route in Rails — it would 404.
 *   2. `GET /api/v1/predictions/:id` uses the MATCH id in the path, even though
 *      Rails calls the parameter `:id`.
 */
import { endpoints } from "@/services/api/endpoints";

describe("API endpoints", () => {
  it("builds every path under /api/v1", () => {
    const paths = [
      endpoints.health(),
      endpoints.ready(),
      endpoints.competitions(),
      endpoints.teams(),
      endpoints.seasons(),
      endpoints.matches(),
      endpoints.predictions(),
      endpoints.predictionsForMatch(4280),
      endpoints.modelStatus(),
      endpoints.syncStatus(),
    ];

    for (const path of paths) {
      expect(path.startsWith("/api/v1/")).toBe(true);
    }
  });

  it("addresses the POST collection without an id segment", () => {
    // A match id in this path is a 404: Rails has no such route.
    expect(endpoints.predictions()).toBe("/api/v1/predictions");
  });

  it("addresses stored predictions by MATCH id", () => {
    expect(endpoints.predictionsForMatch(4280)).toBe(
      "/api/v1/predictions/4280",
    );
  });

  it("serialises match filters and omits absent ones", () => {
    expect(endpoints.matches()).toBe("/api/v1/matches");
    expect(endpoints.matches({ seasonId: 5 })).toBe(
      "/api/v1/matches?season_id=5",
    );
    expect(
      endpoints.matches({ seasonId: 5, status: "scheduled", limit: 20 }),
    ).toBe("/api/v1/matches?season_id=5&status=scheduled&limit=20");
    // undefined/falsy values must not become "season_id=undefined".
    expect(endpoints.matches({ seasonId: undefined, status: undefined })).toBe(
      "/api/v1/matches",
    );
  });

  it("serialises season filters", () => {
    expect(endpoints.seasons()).toBe("/api/v1/seasons");
    expect(endpoints.seasons({ competitionId: 4, withMatches: true })).toBe(
      "/api/v1/seasons?competition_id=4&with_matches=true",
    );
  });

  it("serialises prediction collection filters", () => {
    expect(endpoints.predictions({ matchId: 4280, limit: 10 })).toBe(
      "/api/v1/predictions?match_id=4280&limit=10",
    );
    expect(endpoints.predictions({ market: "1x2", includeHistory: true })).toBe(
      "/api/v1/predictions?market=1x2&include_history=true",
    );
  });
});
