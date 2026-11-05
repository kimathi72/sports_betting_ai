/**
 * Pure rules for the Fixtures screen's collapsible season sections.
 *
 * WHY PURE
 * --------
 * The visible behaviour (which section is open, what an empty list means) is the
 * part that gets the user's claim wrong, so it is decided here and tested without
 * rendering. A screen that computed these inline could only be checked by
 * mounting it.
 */
import type { Match } from "@/types/api";

/**
 * Why an upcoming list is empty.
 *
 * These are genuinely different facts and must never be collapsed into one
 * message:
 *
 *  - `no-fixtures`: the season really has no scheduled matches.
 *  - `not-synced`: the season has no matches at all, so nothing has been
 *    imported for it yet. Saying "no upcoming fixtures" here would imply the
 *    fixture list was checked and is empty, which is not known.
 *  - `unsupported-provider`: the provider cannot serve upcoming fixtures for
 *    this competition at all (see the backend's EspnLeagueCoverage). The user
 *    should stop waiting for data that will not arrive.
 */
export type UpcomingEmptyReason =
  | "no-fixtures"
  | "not-synced"
  | "unsupported-provider";

export interface UpcomingEmptyInput {
  /** Matches returned for the season with status=scheduled. */
  scheduledCount: number;
  /** Total matches the API reports for the season (any status). */
  seasonMatchCount: number;
  /** True when the competition has no verified upcoming-fixture provider. */
  providerUnsupported: boolean;
}

export function upcomingEmptyReason({
  scheduledCount,
  seasonMatchCount,
  providerUnsupported,
}: UpcomingEmptyInput): UpcomingEmptyReason | null {
  if (scheduledCount > 0) {
    return null;
  }
  // Checked first: a competition with no feed is unsupported whether or not it
  // has history, because no future import will change the answer.
  if (providerUnsupported) {
    return "unsupported-provider";
  }
  if (seasonMatchCount <= 0) {
    return "not-synced";
  }
  return "no-fixtures";
}

export const UPCOMING_EMPTY_COPY: Record<
  UpcomingEmptyReason,
  { title: string; message: string }
> = {
  "no-fixtures": {
    title: "No upcoming fixtures",
    message: "This season has no scheduled matches at the moment.",
  },
  "not-synced": {
    title: "Fixtures not synchronised yet",
    message:
      "No matches have been imported for this season. Check back after the next synchronization.",
  },
  "unsupported-provider": {
    title: "No upcoming fixture source",
    message:
      "Upcoming fixtures are not available for this competition yet. Historical results are unaffected.",
  },
};

/**
 * Which season sections start open.
 *
 * The current season opens; older ones stay collapsed so the screen is a short
 * list of headings rather than a wall of matches. A user-opened section is not
 * reset by this: the screen tracks explicit overrides separately.
 */
export function defaultExpandedSeasonIds(
  seasons: readonly { id: number; name: string }[],
  currentSeasonName: string | undefined,
): Set<number> {
  const current = seasons.find((season) => season.name === currentSeasonName);
  return current ? new Set([current.id]) : new Set();
}

/**
 * Sort seasons newest first for display.
 *
 * Labels are "2026/27", so the leading year sorts them; a plain string sort would
 * put "2016/17" before "2025/26" only by luck of zero-padded years.
 */
export function sortSeasonsNewestFirst<T extends { name: string }>(
  seasons: readonly T[],
): T[] {
  return [...seasons].sort((a, b) => b.name.localeCompare(a.name));
}

/** Groups matches by season id, for rendering one section per season. */
export function groupMatchesBySeason(
  matches: readonly Match[],
): Map<number, Match[]> {
  const map = new Map<number, Match[]>();
  for (const match of matches) {
    const bucket = map.get(match.season_id);
    if (bucket) {
      bucket.push(match);
    } else {
      map.set(match.season_id, [match]);
    }
  }
  return map;
}
