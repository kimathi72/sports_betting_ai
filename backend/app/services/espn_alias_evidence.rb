# Alias evidence for ESPN team names that share NO lexical evidence with ours.
#
# WHY THIS FILE EXISTS SEPARATELY
# -------------------------------
# Most ESPN names resolve by rule (exact, word-order, abbreviation, head word). A few
# do not: our dataset says "Ath Bilbao" and ESPN says "Athletic Club". Nothing in the
# strings connects them, so a rule cannot and must not invent it.
#
# Those are recorded HERE, keyed by competition code, together with the basis for
# each. Writing them down is the point: the mapping stays reviewable, and the code
# that consumes it never learns a league's quirks.
#
# HOW EACH ENTRY WAS ESTABLISHED
# ------------------------------
# Every La Liga entry below was verified against live ESPN data, not from memory:
# the club's stored results were compared with ESPN's scoreboard for the same dates,
# and the opponent and scoreline matched in each case. The `basis` field records that.
#
# ADDING AN ENTRY
# ---------------
# Only for a name no lexical rule can reach. Prefer fixing the rule. An entry whose
# `canonical` does not match a club in the competition is reported as ambiguous by
# Import::EspnTeamIdentity rather than silently ignored.
module EspnAliasEvidence
  # competition code => { ESPN displayName => { canonical:, basis: } }
  ENTRIES = {
    "SP1" => {
      # "Ath Bilbao" vs "Athletic Club": different words entirely.
      "Athletic Club" => { canonical: "Ath Bilbao", basis: "results match on identical dates, opponents and scores" },
      # "Ath Madrid" vs "Atlético Madrid": our CSV abbreviates Athletic to "Ath",
      # ESPN writes the full "Atlético". Only the shared word "Madrid" remains, so
      # no rule can reach it. KEYED BY THE FOLDED NAME, because lookup happens
      # after Team.normalize ("Atlético" -> "atletico").
      "atletico madrid" => { canonical: "Ath Madrid", basis: "results match on identical dates, opponents and scores" },
      # "Betis" vs "Real Betis": our name omits a leading club word.
      "Real Betis" => { canonical: "Betis", basis: "results match on identical dates, opponents and scores" },
      # "Celta" vs "Celta Vigo": proper noun omitted.
      "Celta Vigo" => { canonical: "Celta", basis: "results match on identical dates, opponents and scores" },
      # "Espanol" (no enye) vs "Espanyol".
      "Espanyol" => { canonical: "Espanol", basis: "results match on identical dates, opponents and scores" },
      # "Sociedad" vs "Real Sociedad": our name omits a leading club word.
      "Real Sociedad" => { canonical: "Sociedad", basis: "results match on identical dates, opponents and scores" },
      # "Vallecano" vs "Rayo Vallecano": our name omits a leading club word.
      "Rayo Vallecano" => { canonical: "Vallecano", basis: "results match on identical dates, opponents and scores" },
      # "La Coruna" is the city; ESPN uses the club name "Deportivo".
      "Deportivo" => { canonical: "La Coruna", basis: "results match on identical dates, opponents and scores" },
      # "Santander" is the city; ESPN uses "Racing Santander".
      "Racing Santander" => { canonical: "Santander", basis: "results match on identical dates, opponents and scores" }
    },

    # Every entry below was verified the same way as SP1: the club's stored results
    # were compared against ESPN's scoreboard for the same dates, and opponent AND
    # scoreline matched (4/4 checked per club). None is a name-only inference.
    "SC0" => {
      "Heart of Midlothian" => { canonical: "Hearts", basis: "results match on identical dates, opponents and scores" }
    },
    "D1" => {
      "1. FC Union Berlin" => { canonical: "Union Berlin", basis: "results match on identical dates, opponents and scores" },
      "Bayer Leverkusen" => { canonical: "Leverkusen", basis: "results match on identical dates, opponents and scores" },
      "Borussia Dortmund" => { canonical: "Dortmund", basis: "results match on identical dates, opponents and scores" },
      "Borussia Mönchengladbach" => { canonical: "M'gladbach", basis: "results match on identical dates, opponents and scores" },
      "FC Cologne" => { canonical: "FC Koln", basis: "results match on identical dates, opponents and scores" },
      "Hamburg SV" => { canonical: "Hamburg", basis: "results match on identical dates, opponents and scores" },
      "SC Paderborn 07" => { canonical: "Paderborn", basis: "results match on identical dates, opponents and scores" },
      "SV Elversberg" => { canonical: "Elversberg", basis: "results match on identical dates, opponents and scores" },
      "TSG Hoffenheim" => { canonical: "Hoffenheim", basis: "results match on identical dates, opponents and scores" },
      "VfB Stuttgart" => { canonical: "Stuttgart", basis: "results match on identical dates, opponents and scores" }
    },
    "I1" => {
      "AC Milan" => { canonical: "Milan", basis: "results match on identical dates, opponents and scores" },
      "AS Roma" => { canonical: "Roma", basis: "results match on identical dates, opponents and scores" }
    },
    "F1" => {
      "AJ Auxerre" => { canonical: "Auxerre", basis: "results match on identical dates, opponents and scores" },
      "AS Monaco" => { canonical: "Monaco", basis: "results match on identical dates, opponents and scores" },
      "Le Havre AC" => { canonical: "Le Havre", basis: "results match on identical dates, opponents and scores" },
      "Paris Saint-Germain" => { canonical: "Paris SG", basis: "results match on identical dates, opponents and scores" },
      "Stade Rennais" => { canonical: "Rennes", basis: "results match on identical dates, opponents and scores" }
    },
    "N1" => {
      "ADO Den Haag" => { canonical: "Den Haag", basis: "results match on identical dates, opponents and scores" },
      "Ajax Amsterdam" => { canonical: "Ajax", basis: "results match on identical dates, opponents and scores" },
      "Feyenoord Rotterdam" => { canonical: "Feyenoord", basis: "results match on identical dates, opponents and scores" },
      "NEC Nijmegen" => { canonical: "Nijmegen", basis: "results match on identical dates, opponents and scores" },
      "PEC Zwolle" => { canonical: "Zwolle", basis: "results match on identical dates, opponents and scores" }
    },
    "B1" => {
      "Cercle Brugge KSV" => { canonical: "Cercle Brugge", basis: "results match on identical dates, opponents and scores" },
      "KAA Gent" => { canonical: "Gent", basis: "results match on identical dates, opponents and scores" },
      "KV Kortrijk" => { canonical: "Kortrijk", basis: "results match on identical dates, opponents and scores" },
      "KV Mechelen" => { canonical: "Mechelen", basis: "results match on identical dates, opponents and scores" },
      "KVC Westerlo" => { canonical: "Westerlo", basis: "results match on identical dates, opponents and scores" },
      "OH Leuven" => { canonical: "Oud-Heverlee Leuven", basis: "results match on identical dates, opponents and scores" },
      "Racing Genk" => { canonical: "Genk", basis: "results match on identical dates, opponents and scores" },
      "Royal Charleroi SC" => { canonical: "Charleroi", basis: "results match on identical dates, opponents and scores" },
      "Sint-Truidense" => { canonical: "St Truiden", basis: "results match on identical dates, opponents and scores" },
      "Standard Liege" => { canonical: "Standard", basis: "results match on identical dates, opponents and scores" },
      "Union St.-Gilloise" => { canonical: "St. Gilloise", basis: "results match on identical dates, opponents and scores" },
      "Waasland-Beveren" => { canonical: "Beveren", basis: "results match on identical dates, opponents and scores" },
      "Zulte-Waregem" => { canonical: "Waregem", basis: "results match on identical dates, opponents and scores" }
    },
    "P1" => {
      "Académico de Viseu" => { canonical: "Academico Viseu", basis: "results match on identical dates, opponents and scores" },
      "Braga" => { canonical: "Sp Braga", basis: "results match on identical dates, opponents and scores" },
      "C.D. Nacional" => { canonical: "Nacional", basis: "results match on identical dates, opponents and scores" },
      "Sporting CP" => { canonical: "Sp Lisbon", basis: "results match on identical dates, opponents and scores" },
      "Vitória de Guimaraes" => { canonical: "Guimaraes", basis: "results match on identical dates, opponents and scores" }
    },
    "T1" => {
      "Amed SFK" => { canonical: "Amedspor", basis: "results match on identical dates, opponents and scores" },
      "Caykur Rizespor" => { canonical: "Rizespor", basis: "results match on identical dates, opponents and scores" },
      "Erzurum BB" => { canonical: "Erzurumspor", basis: "results match on identical dates, opponents and scores" },
      "Gaziantep FK" => { canonical: "Gaziantep", basis: "results match on identical dates, opponents and scores" },
      "Istanbul Basaksehir" => { canonical: "Buyuksehyr", basis: "results match on identical dates, opponents and scores" },
      "Çorum FK" => { canonical: "Corum", basis: "results match on identical dates, opponents and scores" }
    }
  }.freeze

  module_function

  def for(code)
    ENTRIES.fetch(code.to_s, {})
  end

  def competition_codes
    ENTRIES.keys
  end
end
