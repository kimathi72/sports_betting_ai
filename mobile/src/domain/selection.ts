/**
 * Pure selection rules shared by the fixtures and dashboard screens.
 *
 * Kept out of the screens so they can be tested without rendering, and so both
 * screens pick the same season for the same data.
 */
import type { Season } from "@/types/api";

/**
 * The season a screen should open on.
 *
 * The API orders seasons by name DESCENDING, but names are opaque strings
 * ("2026/27"), so relying on order would break the moment a provider changes
 * its naming. Instead: prefer the season with the most fixtures still to be
 * played, which is the one a user actually wants. Falls back to the largest
 * season, then to the first entry.
 */
export function pickDefaultSeason(seasons: readonly Season[]): Season | null {
  if (seasons.length === 0) {
    return null;
  }

  const withUpcoming = [...seasons].sort(
    (a, b) =>
      b.match_count -
        b.completed_match_count -
        (a.match_count - a.completed_match_count) ||
      b.match_count - a.match_count,
  );

  const best = withUpcoming[0];
  if (best && best.match_count - best.completed_match_count > 0) {
    return best;
  }

  const largest = [...seasons].sort((a, b) => b.match_count - a.match_count)[0];
  return largest ?? seasons[0] ?? null;
}

/** The next N fixtures by kickoff, excluding anything already played. */
export function upcomingMatches<
  T extends { kickoff_at: string; status: string },
>(matches: readonly T[], limit: number, now: Date = new Date()): T[] {
  return matches
    .filter(
      (match) => match.status === "scheduled" || match.status === "in_progress",
    )
    .filter((match) => {
      const kickoff = new Date(match.kickoff_at);
      return (
        !Number.isNaN(kickoff.getTime()) && kickoff.getTime() >= now.getTime()
      );
    })
    .sort(
      (a, b) =>
        new Date(a.kickoff_at).getTime() - new Date(b.kickoff_at).getTime(),
    )
    .slice(0, limit);
}

/** Builds an id → name lookup for a reference collection. */
export function nameMap<T extends { id: number; name: string }>(
  items: readonly T[] | undefined,
): Map<number, string> {
  const map = new Map<number, string>();
  for (const item of items ?? []) {
    map.set(item.id, item.name);
  }
  return map;
}
