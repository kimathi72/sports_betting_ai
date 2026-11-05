/**
 * Completed results must read newest-first; upcoming fixtures must not move.
 *
 * WHY THIS IS A DOMAIN FUNCTION AND NOT AN INLINE `.sort()`
 * ---------------------------------------------------------
 * The ordering rule has three parts that are easy to get subtly wrong and
 * impossible to check by looking at a screen: which direction, which field, and
 * what happens to a row whose timestamp is missing or unparseable. Deciding it
 * here means the rule is tested without rendering, and both list screens share
 * one implementation instead of drifting apart.
 *
 * WHY NOT SERVER-SIDE
 * -------------------
 * `GET /api/v1/matches` orders by `kickoff_at ASC, id ASC` and applies `limit`
 * AFTER ordering. Reversing that server-side would return the OLDEST rows of a
 * capped page, and would change the contract for every other consumer (the ML
 * service, the upcoming list). The ordering is therefore a presentation concern
 * and belongs in the client.
 */
import { orderMatchesForDisplay } from "@/domain/matchOrdering";
import type { Match } from "@/types/api";

function match(overrides: Partial<Match> & { id: number }): Match {
  return {
    competition_id: 1,
    season_id: 1,
    home_team_id: 10,
    away_team_id: 20,
    kickoff_at: "2026-11-01T15:00:00Z",
    status: "completed",
    home_score: 1,
    away_score: 0,
    ...overrides,
  };
}

describe("orderMatchesForDisplay — completed results", () => {
  it("puts the most recently completed match first", () => {
    const ordered = orderMatchesForDisplay(
      [
        match({ id: 1, kickoff_at: "2026-08-15T15:00:00Z" }),
        match({ id: 2, kickoff_at: "2026-11-02T20:00:00Z" }),
        match({ id: 3, kickoff_at: "2026-09-20T15:00:00Z" }),
      ],
      "completed",
    );

    expect(ordered.map((m) => m.id)).toEqual([2, 3, 1]);
  });

  it("puts the oldest completed match last", () => {
    const ordered = orderMatchesForDisplay(
      [
        match({ id: 1, kickoff_at: "2026-08-15T15:00:00Z" }),
        match({ id: 2, kickoff_at: "2026-11-02T20:00:00Z" }),
      ],
      "completed",
    );

    expect(ordered[ordered.length - 1].id).toBe(1);
  });

  it("sorts by kickoff timestamp, not by id", () => {
    // Ids deliberately run opposite to kickoff order: a sort by id would pass a
    // naive test but show the wrong match first.
    const ordered = orderMatchesForDisplay(
      [
        match({ id: 900, kickoff_at: "2026-08-15T15:00:00Z" }),
        match({ id: 100, kickoff_at: "2026-11-02T20:00:00Z" }),
      ],
      "completed",
    );

    expect(ordered.map((m) => m.id)).toEqual([100, 900]);
  });

  it("orders matches across several dates correctly", () => {
    const ordered = orderMatchesForDisplay(
      [
        match({ id: 1, kickoff_at: "2026-10-31T15:00:00Z" }),
        match({ id: 2, kickoff_at: "2026-11-02T20:00:00Z" }),
        match({ id: 3, kickoff_at: "2026-11-01T12:30:00Z" }),
        match({ id: 4, kickoff_at: "2026-11-01T15:00:00Z" }),
      ],
      "completed",
    );

    expect(ordered.map((m) => m.id)).toEqual([2, 4, 3, 1]);
  });

  it("orders same-day fixtures by time of day, latest first", () => {
    const ordered = orderMatchesForDisplay(
      [
        match({ id: 1, kickoff_at: "2026-11-01T12:30:00Z" }),
        match({ id: 2, kickoff_at: "2026-11-01T17:30:00Z" }),
        match({ id: 3, kickoff_at: "2026-11-01T15:00:00Z" }),
      ],
      "completed",
    );

    expect(ordered.map((m) => m.id)).toEqual([2, 3, 1]);
  });

  it("breaks a kickoff tie deterministically by id, descending", () => {
    const ordered = orderMatchesForDisplay(
      [
        match({ id: 5, kickoff_at: "2026-11-01T15:00:00Z" }),
        match({ id: 9, kickoff_at: "2026-11-01T15:00:00Z" }),
        match({ id: 7, kickoff_at: "2026-11-01T15:00:00Z" }),
      ],
      "completed",
    );

    expect(ordered.map((m) => m.id)).toEqual([9, 7, 5]);
  });

  it("places a missing kickoff last, deterministically", () => {
    const ordered = orderMatchesForDisplay(
      [
        match({ id: 1, kickoff_at: "" }),
        match({ id: 2, kickoff_at: "2026-11-02T20:00:00Z" }),
        match({ id: 3, kickoff_at: "2026-08-15T15:00:00Z" }),
      ],
      "completed",
    );

    expect(ordered.map((m) => m.id)).toEqual([2, 3, 1]);
  });

  it("places an unparseable kickoff last rather than first", () => {
    // `new Date("not-a-date")` is NaN; a naive comparator returns NaN and the
    // sort order becomes implementation-defined. It must be explicit.
    const ordered = orderMatchesForDisplay(
      [
        match({ id: 1, kickoff_at: "not-a-date" }),
        match({ id: 2, kickoff_at: "2026-11-02T20:00:00Z" }),
      ],
      "completed",
    );

    expect(ordered.map((m) => m.id)).toEqual([2, 1]);
  });

  it("orders two missing kickoffs deterministically by id", () => {
    const ordered = orderMatchesForDisplay(
      [
        match({ id: 4, kickoff_at: "" }),
        match({ id: 8, kickoff_at: "" }),
      ],
      "completed",
    );

    expect(ordered.map((m) => m.id)).toEqual([8, 4]);
  });

  it("does not mutate the input array", () => {
    const input = [
      match({ id: 1, kickoff_at: "2026-08-15T15:00:00Z" }),
      match({ id: 2, kickoff_at: "2026-11-02T20:00:00Z" }),
    ];
    const snapshot = input.map((m) => m.id);

    orderMatchesForDisplay(input, "completed");

    expect(input.map((m) => m.id)).toEqual(snapshot);
  });
});

describe("orderMatchesForDisplay — upcoming fixtures", () => {
  it("keeps the server's ascending order", () => {
    const ordered = orderMatchesForDisplay(
      [
        match({ id: 1, status: "scheduled", kickoff_at: "2026-11-06T20:00:00Z", home_score: null, away_score: null }),
        match({ id: 2, status: "scheduled", kickoff_at: "2026-11-08T15:00:00Z", home_score: null, away_score: null }),
        match({ id: 3, status: "scheduled", kickoff_at: "2026-11-22T15:00:00Z", home_score: null, away_score: null }),
      ],
      "scheduled",
    );

    expect(ordered.map((m) => m.id)).toEqual([1, 2, 3]);
  });

  it("returns the same array instance when no reordering is needed", () => {
    // Avoids a redundant copy on every render of the upcoming list.
    const input = [match({ id: 1, status: "scheduled" })];

    expect(orderMatchesForDisplay(input, "scheduled")).toBe(input);
  });
});

describe("orderMatchesForDisplay — mixed and unfiltered lists", () => {
  it("leaves an unfiltered list in server order", () => {
    const input = [
      match({ id: 1, kickoff_at: "2026-08-15T15:00:00Z" }),
      match({ id: 2, status: "scheduled", kickoff_at: "2026-11-08T15:00:00Z" }),
    ];

    expect(orderMatchesForDisplay(input, undefined)).toBe(input);
  });

  it("handles an empty list", () => {
    expect(orderMatchesForDisplay([], "completed")).toEqual([]);
  });
});
