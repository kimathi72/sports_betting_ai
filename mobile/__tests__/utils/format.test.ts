/**
 * Formatters.
 *
 * The relative-time function is tested against a fixed `now` so the assertions
 * do not depend on the clock. Score formatting is tested for the null case
 * specifically, because the backend sends `null` for both scores until a match
 * completes and rendering "0 - 0" there would be a lie.
 */
import {
  formatRelative,
  formatScore,
  formatMatchStatus,
  formatSeasonName,
  formatTime,
  parseTimestamp,
} from "@/utils/format";

const NOW = new Date("2026-10-30T12:00:00Z");

describe("parseTimestamp", () => {
  it("parses a valid ISO string", () => {
    expect(parseTimestamp("2026-10-30T08:38:24Z")).toBeInstanceOf(Date);
  });

  it("returns null for null, undefined and malformed input", () => {
    expect(parseTimestamp(null)).toBeNull();
    expect(parseTimestamp(undefined)).toBeNull();
    expect(parseTimestamp("not-a-date")).toBeNull();
  });
});

describe("formatRelative", () => {
  it('reports "never" when there is no timestamp', () => {
    expect(formatRelative(null, NOW)).toBe("never");
  });

  it("rounds to the nearest sensible unit", () => {
    expect(formatRelative("2026-10-30T11:59:30Z", NOW)).toBe("just now");
    expect(formatRelative("2026-10-30T11:30:00Z", NOW)).toBe("30m ago");
    expect(formatRelative("2026-10-30T10:00:00Z", NOW)).toBe("2h ago");
    expect(formatRelative("2026-10-27T12:00:00Z", NOW)).toBe("3d ago");
  });

  it("treats a future timestamp as clock skew, not an error", () => {
    expect(formatRelative("2026-10-30T13:00:00Z", NOW)).toBe("just now");
  });
});

describe("formatScore", () => {
  it("formats a completed score", () => {
    expect(formatScore(2, 1)).toBe("2 - 1");
  });

  it("returns null when either score is missing", () => {
    expect(formatScore(null, null)).toBeNull();
    expect(formatScore(2, null)).toBeNull();
  });

  it('renders a genuine goalless draw, not as "no score"', () => {
    expect(formatScore(0, 0)).toBe("0 - 0");
  });
});

describe("formatMatchStatus", () => {
  it("labels every documented status", () => {
    expect(formatMatchStatus("scheduled")).toBe("Scheduled");
    expect(formatMatchStatus("completed")).toBe("Full time");
    expect(formatMatchStatus("postponed")).toBe("Postponed");
  });

  it("passes an unknown status through rather than hiding it", () => {
    expect(formatMatchStatus("abandoned")).toBe("abandoned");
  });
});

describe("formatTime", () => {
  it("returns a HH:MM string", () => {
    expect(formatTime("2026-12-26T15:00:00Z")).toMatch(/^\d{2}:\d{2}$/);
  });

  it("degrades gracefully on bad input", () => {
    expect(formatTime("nonsense")).toBe("--:--");
  });
});

describe("formatSeasonName", () => {
  it("falls back when the name is missing", () => {
    expect(formatSeasonName(null)).toBe("Season");
    expect(formatSeasonName("  ")).toBe("Season");
    expect(formatSeasonName("2026/27")).toBe("2026/27");
  });
});
