/**
 * Fixtures screen section rules.
 *
 * The empty-state distinction is the part that can quietly lie to the user:
 * "no upcoming fixtures" and "nothing has been imported yet" look identical on
 * screen but mean different things, and one of them is a promise that tomorrow's
 * sync will not keep.
 */
import {
  UPCOMING_EMPTY_COPY,
  defaultExpandedSeasonIds,
  groupMatchesBySeason,
  sortSeasonsNewestFirst,
  upcomingEmptyReason,
} from "@/domain/fixtureSections";
import type { Match } from "@/types/api";

function match(id: number, seasonId: number): Match {
  return {
    id,
    season_id: seasonId,
    competition_id: 1,
    home_team_id: 1,
    away_team_id: 2,
    kickoff_at: "2026-11-21T12:30:00Z",
    status: "scheduled",
    home_score: null,
    away_score: null,
  } as Match;
}

describe("upcomingEmptyReason", () => {
  it("returns null when there are scheduled fixtures", () => {
    expect(
      upcomingEmptyReason({
        scheduledCount: 12,
        seasonMatchCount: 100,
        providerUnsupported: false,
      }),
    ).toBeNull();
  });

  it("reports not-synced when the season holds no matches at all", () => {
    // Nothing imported: claiming "no upcoming fixtures" would assert the list was
    // checked and is empty, which is not known.
    expect(
      upcomingEmptyReason({
        scheduledCount: 0,
        seasonMatchCount: 0,
        providerUnsupported: false,
      }),
    ).toBe("not-synced");
  });

  it("reports no-fixtures when the season has history but nothing upcoming", () => {
    expect(
      upcomingEmptyReason({
        scheduledCount: 0,
        seasonMatchCount: 380,
        providerUnsupported: false,
      }),
    ).toBe("no-fixtures");
  });

  it("reports unsupported-provider even when the season has history", () => {
    // History present, no feed: waiting for a sync will never help.
    expect(
      upcomingEmptyReason({
        scheduledCount: 0,
        seasonMatchCount: 380,
        providerUnsupported: true,
      }),
    ).toBe("unsupported-provider");
  });

  it("prefers unsupported-provider over not-synced for an empty unsupported competition", () => {
    expect(
      upcomingEmptyReason({
        scheduledCount: 0,
        seasonMatchCount: 0,
        providerUnsupported: true,
      }),
    ).toBe("unsupported-provider");
  });

  it("has distinct copy for every reason", () => {
    const titles = Object.values(UPCOMING_EMPTY_COPY).map((copy) => copy.title);
    expect(new Set(titles).size).toBe(titles.length);
    expect(UPCOMING_EMPTY_COPY["not-synced"].title).not.toBe(
      UPCOMING_EMPTY_COPY["no-fixtures"].title,
    );
  });
});

describe("defaultExpandedSeasonIds", () => {
  const seasons = [
    { id: 3, name: "2026/27" },
    { id: 2, name: "2025/26" },
    { id: 1, name: "2024/25" },
  ];

  it("opens only the current season", () => {
    expect(defaultExpandedSeasonIds(seasons, "2026/27")).toEqual(new Set([3]));
  });

  it("leaves older seasons collapsed", () => {
    const expanded = defaultExpandedSeasonIds(seasons, "2026/27");
    expect(expanded.has(2)).toBe(false);
    expect(expanded.has(1)).toBe(false);
  });

  it("expands nothing when the current season is unknown", () => {
    expect(defaultExpandedSeasonIds(seasons, undefined).size).toBe(0);
    expect(defaultExpandedSeasonIds(seasons, "2099/00").size).toBe(0);
  });

  it("handles an empty season list", () => {
    expect(defaultExpandedSeasonIds([], "2026/27").size).toBe(0);
  });
});

describe("sortSeasonsNewestFirst", () => {
  it("puts the newest season first", () => {
    const sorted = sortSeasonsNewestFirst([
      { id: 1, name: "2016/17" },
      { id: 3, name: "2026/27" },
      { id: 2, name: "2020/21" },
    ]);
    expect(sorted.map((s) => s.name)).toEqual([
      "2026/27",
      "2020/21",
      "2016/17",
    ]);
  });

  it("does not mutate the input", () => {
    const input = [{ name: "2016/17" }, { name: "2026/27" }];
    sortSeasonsNewestFirst(input);
    expect(input.map((s) => s.name)).toEqual(["2016/17", "2026/27"]);
  });
});

describe("groupMatchesBySeason", () => {
  it("groups matches under their own season", () => {
    const grouped = groupMatchesBySeason([
      match(1, 3),
      match(2, 3),
      match(3, 2),
    ]);
    expect(grouped.get(3)?.map((m) => m.id)).toEqual([1, 2]);
    expect(grouped.get(2)?.map((m) => m.id)).toEqual([3]);
  });

  it("returns an empty map for no matches", () => {
    expect(groupMatchesBySeason([]).size).toBe(0);
  });
});
