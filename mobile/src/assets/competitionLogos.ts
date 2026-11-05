/**
 * Competition logos, keyed by the catalogue code Rails returns in `competition.code`.
 *
 * Every URL was read from ESPN's league metadata and fetched successfully (HTTP 200,
 * image body) before being committed, so the map contains only images that exist.
 * The key is the catalogue code (E0, SP1, uefa.champions, …) rather than the display
 * name, because the code is what the API sends and it does not change if a
 * competition is renamed for display.
 *
 * A code that is not here renders the monogram fallback in `CompetitionLogo`: an
 * unknown competition gets a neutral mark, never another league's badge.
 */
export const COMPETITION_LOGOS: Record<string, string> = {
  E0: "https://a.espncdn.com/i/leaguelogos/soccer/500/23.png",
  E1: "https://a.espncdn.com/i/leaguelogos/soccer/500/24.png",
  SP1: "https://a.espncdn.com/i/leaguelogos/soccer/500/15.png",
  D1: "https://a.espncdn.com/i/leaguelogos/soccer/500/10.png",
  I1: "https://a.espncdn.com/i/leaguelogos/soccer/500/12.png",
  F1: "https://a.espncdn.com/i/leaguelogos/soccer/500/9.png",
  P1: "https://a.espncdn.com/i/leaguelogos/soccer/500/14.png",
  N1: "https://a.espncdn.com/i/leaguelogos/soccer/500/11.png",
  B1: "https://a.espncdn.com/i/leaguelogos/soccer/500/6.png",
  SC0: "https://a.espncdn.com/i/leaguelogos/soccer/500/45.png",
  T1: "https://a.espncdn.com/i/leaguelogos/soccer/500/18.png",
  "uefa.champions": "https://a.espncdn.com/i/leaguelogos/soccer/500/2.png",
};

export function logoForCompetition(
  code: string | null | undefined,
): string | null {
  if (!code) return null;
  return COMPETITION_LOGOS[code] ?? null;
}
