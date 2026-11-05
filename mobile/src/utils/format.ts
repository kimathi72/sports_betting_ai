/**
 * Date, time and score formatting.
 *
 * Every screen formats through these functions. Backend timestamps are UTC ISO
 * 8601 strings; they are rendered in the device's local timezone, which is the
 * only sensible choice for a kickoff time a user is planning around.
 */

/** Parses an ISO timestamp, returning null instead of an Invalid Date. */
export function parseTimestamp(iso: string | null | undefined): Date | null {
  if (!iso) {
    return null;
  }
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? null : date;
}

/**
 * Kickoff rendering differs by platform because `Intl` support is not uniform
 * across Hermes builds. The fallback is deterministic and still shows local time.
 */
export function formatKickoff(iso: string): string {
  const date = parseTimestamp(iso);
  if (!date) {
    return "Kickoff time unknown";
  }

  try {
    return new Intl.DateTimeFormat(undefined, {
      weekday: "short",
      day: "2-digit",
      month: "short",
      hour: "2-digit",
      minute: "2-digit",
    }).format(date);
  } catch {
    return date.toLocaleString();
  }
}

/** Just the clock time, e.g. "15:00" in local time. */
export function formatTime(iso: string): string {
  const date = parseTimestamp(iso);
  if (!date) {
    return "--:--";
  }
  const hours = date.getHours().toString().padStart(2, "0");
  const minutes = date.getMinutes().toString().padStart(2, "0");
  return `${hours}:${minutes}`;
}

/** Just the calendar date, e.g. "26 Dec 2026". */
export function formatDate(iso: string | null): string {
  const date = parseTimestamp(iso);
  if (!date) {
    return "Unknown date";
  }
  try {
    return new Intl.DateTimeFormat(undefined, {
      day: "2-digit",
      month: "short",
      year: "numeric",
    }).format(date);
  } catch {
    return date.toDateString();
  }
}

/**
 * Relative freshness, e.g. "2h ago", "just now".
 *
 * Used for synchronization and model timestamps, where "how stale is this?"
 * matters far more than the exact instant.
 */
export function formatRelative(
  iso: string | null,
  now: Date = new Date(),
): string {
  const date = parseTimestamp(iso);
  if (!date) {
    return "never";
  }

  const seconds = Math.floor((now.getTime() - date.getTime()) / 1000);
  if (seconds < 0) {
    // A timestamp slightly in the future is clock skew, not an error.
    return "just now";
  }
  if (seconds < 60) {
    return "just now";
  }

  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) {
    return `${minutes}m ago`;
  }

  const hours = Math.floor(minutes / 60);
  if (hours < 24) {
    return `${hours}h ago`;
  }

  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}

/** "2 - 1", or null while the match has no result. */
export function formatScore(
  homeScore: number | null,
  awayScore: number | null,
): string | null {
  if (homeScore === null || awayScore === null) {
    return null;
  }
  return `${homeScore} - ${awayScore}`;
}

/** Human label for a match status. */
export function formatMatchStatus(status: string): string {
  switch (status) {
    case "scheduled":
      return "Scheduled";
    case "in_progress":
      return "In progress";
    case "completed":
      return "Full time";
    case "postponed":
      return "Postponed";
    case "cancelled":
      return "Cancelled";
    default:
      return status;
  }
}

/** "2026/27" -> "2026/27"; guards nullish season names. */
export function formatSeasonName(name: string | null | undefined): string {
  return name && name.trim().length > 0 ? name : "Season";
}
