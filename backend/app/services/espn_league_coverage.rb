# Covered but not yet importable.
#
# Every code below is in CompetitionCatalogue (names, countries, regions) and is
# downloaded from football-data.co.uk for historical results. None has a verified
# ESPN league slug, so the upcoming-fixture discovery path cannot reach it. They
# are named here, with the reason, so "no fixtures" is explainable rather than a
# mystery, and so adding one later is a deliberate act with an edited constant.
#
# Adding a league to this file does NOT enable it. It documents the gap.
module EspnLeagueCoverage
  # Verified ESPN slugs, one per catalogue code. Only slugs confirmed to return
  # that country's clubs from ESPN's /teams endpoint are listed.
  #
  # WHY THIS IS A CONSTANT AND NOT A GUESS
  # --------------------------------------
  # ESPN slugs are not derivable: `esp.2` exists, `eng.3` does not, and several
  # lower divisions have no slug at all. Guessing one would silently import the
  # wrong division under the right name, which is the kind of error the catalogue
  # exists to prevent.
  VERIFIED = {
    "E0" => "eng.1",
    "E1" => "eng.2",
    "SC0" => "sco.1",
    "SP1" => "esp.1",
    "D1" => "ger.1",
    "I1" => "ita.1",
    "F1" => "fra.1",
    "N1" => "ned.1",
    "B1" => "bel.1",
    "P1" => "por.1",
    "T1" => "tur.1",
  }.freeze

  # Catalogue codes with no usable ESPN fixture feed, and why.
  UNAVAILABLE = {
    "E2" => "ESPN publishes no eng.3 scoreboard (checked: empty events for one day)",
    "E3" => "ESPN publishes no eng.4 scoreboard (checked: HTTP 400). No lower-division feed.",
    "EC" => "ESPN publishes no eng.5 scoreboard (checked: empty events for one day)",
    "SC1" => "ESPN publishes no sco.2 scoreboard (checked: empty events for one day)",
    "SP2" => "ESPN's esp.2 exists but its clubs are not in our dataset; no mapping to verify",
    "D2" => "ESPN's ger.2 exists but its clubs are not in our dataset; no mapping to verify",
    "I2" => "ESPN's ita.2 exists but its clubs are not in our dataset; no mapping to verify",
    "F2" => "ESPN's fra.2 exists but its clubs are not in our dataset; no mapping to verify",
    "G1" => "ESPN's gre.1 exists but its clubs are not in our dataset; no mapping to verify",
    "uefa.champions" => "ESPN serves it, but our dataset has no UCL history to reconcile against",
    "uefa.europa" => "ESPN serves it, but our dataset has no UEL history",
    "uefa.europa.conf" => "ESPN serves it, but our dataset has no Conference League history",
  }.freeze

  # The codes the app is expected to show upcoming fixtures for.
  PRODUCT_SCOPE = %w[E0 E1 SP1 D1 I1 F1 N1 B1 P1 T1 SC0].freeze

  module_function

  # Inverse of VERIFIED, built once from the same constant so the two can never
  # disagree. VERIFIED is keyed CODE => SLUG; callers hold a slug, so this is the
  # direction they actually need.
  SLUG_TO_CODE = VERIFIED.each_with_object({}) { |(code, slug), map| map[slug] = code }.freeze

  def slug_for(code)
    VERIFIED[code.to_s]
  end

  # The catalogue code an ESPN league slug imports into, or nil if unmapped.
  #
  # Nil rather than a guess: `esp.2` and `eng.2` are both "second divisions", and
  # inferring one from the other would file a country's clubs under the wrong
  # competition.
  def code_for_slug(slug)
    return nil if slug.blank?

    SLUG_TO_CODE[slug.to_s]
  end

  def unavailable_reason(code)
    UNAVAILABLE[code.to_s]
  end

  # Codes in the product scope that discovery cannot currently reach.
  def unimportable_scope
    PRODUCT_SCOPE.reject { |code| VERIFIED.key?(code) }
  end
end
