/**
 * Season and fixture selection.
 *
 * `pickDefaultSeason` deliberately does NOT trust the API's order. These tests
 * pin the behaviour that matters: open on a season that still has football to
 * watch, and never crash on an empty or fully-completed season list.
 */
import {
  nameMap,
  pickDefaultSeason,
  upcomingMatches,
} from "@/domain/selection";
import type { Season } from "@/types/api";

function season(
  id: number,
  name: string,
  matchCount: number,
  completed: number,
): Season {
  return {
    id,
    name,
    competition_id: 4,
    match_count: matchCount,
    completed_match_count: completed,
  };
}

describe("pickDefaultSeason", () => {
  it("returns null for an empty list", () => {
    expect(pickDefaultSeason([])).toBeNull();
  });

  it("prefers the season with the most fixtures still to play", () => {
    const seasons = [
      season(1, "2025/26", 380, 380),
      season(2, "2026/27", 380, 80),
    ];

    expect(pickDefaultSeason(seasons)?.id).toBe(2);
  });

  it("falls back to the largest season when every season is finished", () => {
    const seasons = [
      season(1, "2024/25", 380, 380),
      season(2, "2025/26", 200, 200),
    ];

    expect(pickDefaultSeason(seasons)?.id).toBe(1);
  });

  it("does not depend on the order the API returned", () => {
    const a = [season(1, "2025/26", 380, 380), season(2, "2026/27", 380, 10)];
    const b = [...a].reverse();

    expect(pickDefaultSeason(a)?.id).toBe(pickDefaultSeason(b)?.id);
  });
});

describe("upcomingMatches", () => {
  const now = new Date("2026-10-30T12:00:00Z");
  const base = {
    season_id: 5,
    competition_id: 4,
    home_team_id: 1,
    away_team_id: 2,
  };

  it("keeps only scheduled fixtures in the future, soonest first", () => {
    const matches = [
      {
        ...base,
        id: 3,
        kickoff_at: "2026-11-05T15:00:00Z",
        status: "scheduled",
      },
      {
        ...base,
        id: 1,
        kickoff_at: "2026-07-01T15:00:00Z",
        status: "completed",
      },
      {
        ...base,
        id: 2,
        kickoff_at: "2026-11-01T15:00:00Z",
        status: "scheduled",
      },
      {
        ...base,
        id: 4,
        kickoff_at: "2026-10-01T15:00:00Z",
        status: "scheduled",
      },
    ];

    const result = upcomingMatches(matches, 10, now);

    expect(result.map((m) => m.id)).toEqual([2, 3]);
  });

  it("honours the limit", () => {
    const matches = Array.from({ length: 5 }, (_, index) => ({
      ...base,
      id: index,
      kickoff_at: `2026-11-0${index + 1}T15:00:00Z`,
      status: "scheduled",
    }));

    expect(upcomingMatches(matches, 2, now)).toHaveLength(2);
  });

  it("ignores a malformed kickoff instead of crashing", () => {
    const matches = [
      { ...base, id: 9, kickoff_at: "nonsense", status: "scheduled" },
    ];

    expect(upcomingMatches(matches, 10, now)).toEqual([]);
  });
});

describe("nameMap", () => {
  it("indexes by id and tolerates undefined", () => {
    expect(nameMap([{ id: 1, name: "Arsenal" }]).get(1)).toBe("Arsenal");
    expect(nameMap(undefined).size).toBe(0);
  });
});
