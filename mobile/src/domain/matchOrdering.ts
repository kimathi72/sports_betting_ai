/**
 * Display ordering for match lists.
 *
 * WHY THIS IS A DOMAIN FUNCTION AND NOT AN INLINE `.sort()`
 * ---------------------------------------------------------
 * The rule has three parts that are easy to get subtly wrong and impossible to
 * check by looking at a screen: which direction, which field, and what happens to
 * a row whose timestamp is missing or unparseable. Deciding it here means the rule
 * is tested without rendering, and both list screens share one implementation
 * instead of drifting apart.
 *
 * WHY NOT SERVER-SIDE
 * -------------------
 * `GET /api/v1/matches` orders by `kickoff_at ASC, id ASC` and applies `limit`
 * AFTER ordering. Reversing that server-side would return the OLDEST rows of a
 * capped page, and would change the contract for every other consumer (the ML
 * service, the upcoming list). Ordering is therefore a presentation concern and
 * belongs in the client.
 *
 * WHAT IS DELIBERATELY NOT SORTED
 * -------------------------------
 * Only `completed` lists are reversed. Upcoming fixtures keep the server's
 * ascending order — the next match to be played is the one a user wants first —
 * and an unfiltered list keeps whatever order the server chose, because mixing
 * two directions in one list has no correct answer.
 */
import type { Match, MatchStatus } from "@/types/api";

/** Milliseconds since the epoch, or null when the value is absent or invalid. */
function kickoffMillis(match: Match): number | null {
  const raw = match.kickoff_at;
  if (typeof raw !== "string" || raw.length === 0) {
    return null;
  }
  const parsed = new Date(raw).getTime();
  return Number.isNaN(parsed) ? null : parsed;
}

/**
 * Newest kickoff first, then highest id.
 *
 * A missing or unparseable kickoff sorts LAST rather than first: an unknown date
 * is not evidence of a recent match, and putting it at the top would push a real
 * result off the first screen. Two unknown dates fall back to id, descending, so
 * the order is total and stable — a comparator that returns NaN for either side
 * leaves the result implementation-defined.
 */
function compareNewestFirst(a: Match, b: Match): number {
  const aTime = kickoffMillis(a);
  const bTime = kickoffMillis(b);

  if (aTime === null && bTime === null) {
    return b.id - a.id;
  }
  if (aTime === null) {
    return 1;
  }
  if (bTime === null) {
    return -1;
  }
  if (aTime !== bTime) {
    return bTime - aTime;
  }
  return b.id - a.id;
}

/**
 * Orders a match list for display.
 *
 * Returns the SAME array instance when no reordering applies, so a screen that
 * renders an upcoming list does not allocate a copy on every render.
 */
export function orderMatchesForDisplay(
  matches: readonly Match[],
  status: MatchStatus | undefined,
): readonly Match[] {
  if (status !== "completed" || matches.length < 2) {
    return matches;
  }
  return [...matches].sort(compareNewestFirst);
}
