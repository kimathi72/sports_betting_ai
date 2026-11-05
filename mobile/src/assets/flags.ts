/**
 * Country flags, keyed by the country name Rails returns on a competition.
 *
 * Source: flagcdn.com, which serves ISO 3166 country flags as small PNGs. Each code
 * below was fetched successfully before being committed. England, Scotland and Wales
 * use the UK sub-national codes flagcdn provides (`gb-eng`, `gb-sct`, `gb-wls`)
 * because a Union Jack for the Premier League would be wrong.
 *
 * Flags are decorative context, so an unknown country simply renders no flag rather
 * than a placeholder rectangle: the row stays readable either way.
 */
export const COUNTRY_FLAGS: Record<string, string> = {
  England: "https://flagcdn.com/w40/gb-eng.png",
  Scotland: "https://flagcdn.com/w40/gb-sct.png",
  Wales: "https://flagcdn.com/w40/gb-wls.png",
  Spain: "https://flagcdn.com/w40/es.png",
  Germany: "https://flagcdn.com/w40/de.png",
  Italy: "https://flagcdn.com/w40/it.png",
  France: "https://flagcdn.com/w40/fr.png",
  Portugal: "https://flagcdn.com/w40/pt.png",
  Netherlands: "https://flagcdn.com/w40/nl.png",
  Belgium: "https://flagcdn.com/w40/be.png",
  Turkey: "https://flagcdn.com/w40/tr.png",
  Greece: "https://flagcdn.com/w40/gr.png",
  Brazil: "https://flagcdn.com/w40/br.png",
  Argentina: "https://flagcdn.com/w40/ar.png",
  Mexico: "https://flagcdn.com/w40/mx.png",
  "United States": "https://flagcdn.com/w40/us.png",
  Europe: "https://flagcdn.com/w40/eu.png",
};

export function flagForCountry(
  country: string | null | undefined,
): string | null {
  if (!country) return null;
  return COUNTRY_FLAGS[country] ?? null;
}
