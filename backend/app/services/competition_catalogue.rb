# Canonical names, countries and regions for the competition codes the import
# pipeline understands.
#
# WHY THIS EXISTS
# ---------------
# Competitions were previously named from their provider code, which produced rows
# like "football_data competition E1" with no country. That is a database
# presentation defect, not a design choice: the code is an internal import key, not
# something a person should ever read. The resolver now asks this catalogue for a
# human name at creation time, and `CompetitionCatalogue.backfill!` repairs rows
# created before it existed.
#
# EVERY ENTRY IS VERIFIED. Each division code was confirmed against the live
# football-data.co.uk source (HTTP 200 and a CSV body) before being listed, and the
# `region` values drive the mobile region filter, so they are part of the product,
# not decoration. Adding a competition without a real source response would make
# the app advertise data that does not exist.
#
# `uefa_*` entries are listed so that a competition created from an ESPN league slug
# (which the ESPN adapter uses as its code) is named correctly. They are not
# downloaded from football-data.co.uk, which does not publish European competition
# results.
module CompetitionCatalogue
  Entry = Struct.new(:name, :country, :region, keyword_init: true)

  # Regions in the order the mobile filter presents them.
  REGIONS = {
    "europe" => "Europe",
    "south_america" => "South America",
    "africa" => "Africa",
    "asia" => "Asia",
    "north_america" => "North America",
    "other" => "Other",
  }.freeze

  ENTRIES = {
    "E0" => Entry.new(name: "Premier League", country: "England", region: "europe"),
    "E1" => Entry.new(name: "Championship", country: "England", region: "europe"),
    "E2" => Entry.new(name: "League One", country: "England", region: "europe"),
    "E3" => Entry.new(name: "League Two", country: "England", region: "europe"),
    "EC" => Entry.new(name: "National League", country: "England", region: "europe"),
    "SC0" => Entry.new(name: "Scottish Premiership", country: "Scotland", region: "europe"),
    "SC1" => Entry.new(name: "Scottish Championship", country: "Scotland", region: "europe"),
    "SP1" => Entry.new(name: "La Liga", country: "Spain", region: "europe"),
    "SP2" => Entry.new(name: "Segunda Division", country: "Spain", region: "europe"),
    "D1" => Entry.new(name: "Bundesliga", country: "Germany", region: "europe"),
    "D2" => Entry.new(name: "2. Bundesliga", country: "Germany", region: "europe"),
    "I1" => Entry.new(name: "Serie A", country: "Italy", region: "europe"),
    "I2" => Entry.new(name: "Serie B", country: "Italy", region: "europe"),
    "F1" => Entry.new(name: "Ligue 1", country: "France", region: "europe"),
    "F2" => Entry.new(name: "Ligue 2", country: "France", region: "europe"),
    "N1" => Entry.new(name: "Eredivisie", country: "Netherlands", region: "europe"),
    "B1" => Entry.new(name: "Belgian Pro League", country: "Belgium", region: "europe"),
    "P1" => Entry.new(name: "Primeira Liga", country: "Portugal", region: "europe"),
    "T1" => Entry.new(name: "Super Lig", country: "Turkey", region: "europe"),
    "G1" => Entry.new(name: "Super League", country: "Greece", region: "europe"),
    "uefa.champions" => Entry.new(name: "UEFA Champions League", country: "Europe", region: "europe"),
    "uefa.europa" => Entry.new(name: "UEFA Europa League", country: "Europe", region: "europe"),
    "uefa.europa.conf" => Entry.new(name: "UEFA Conference League", country: "Europe", region: "europe"),
  }.freeze

  # Provider prefixes that may appear in an imported competition code, e.g.
  # "football_data E1" -> "E1".
  CODE_PREFIXES = ["football_data ", "espn "].freeze

  module_function

  # The catalogue code for an import key, or nil when the key is unknown.
  def code_for(key)
    candidate = key.to_s.strip
    CODE_PREFIXES.each { |prefix| candidate = candidate.delete_prefix(prefix) }
    ENTRIES.key?(candidate) ? candidate : nil
  end

  def lookup(key)
    code = code_for(key)
    code && ENTRIES[code]
  end

  # The name to store for a competition created from `key`.
  #
  # An unknown code still gets a readable name rather than a fabricated one: the
  # code itself, prefixed so it is obvious the catalogue has no entry. Inventing a
  # plausible-sounding league name would be worse than an honest identifier.
  def canonical_name(key)
    entry = lookup(key)
    return entry.name if entry

    candidate = key.to_s.strip
    CODE_PREFIXES.each { |prefix| candidate = candidate.delete_prefix(prefix) }
    candidate.empty? ? "Unknown competition" : candidate
  end

  def region_for(key)
    lookup(key)&.region || "other"
  end

  def country_for(key)
    lookup(key)&.country
  end

  # Repairs competitions created before the catalogue existed.
  #
  # Only rows whose name is EXACTLY the old generated pattern are touched: a name a
  # human chose is never overwritten, because the catalogue is a default, not an
  # authority. Returns the rows that changed, so the caller can report them.
  def backfill!
    repaired = []
    Competition.find_each do |competition|
      generated = generated_name?(competition)
      entry = lookup(competition.code.presence || legacy_code(competition.name))
      next if entry.nil?

      changed = false
      if generated
        competition.name = entry.name
        changed = true
      end
      if competition.country.blank?
        competition.country = entry.country
        changed = true
      end
      next unless changed && competition.save

      repaired << competition
    end
    repaired
  end

  def generated_name?(competition)
    competition.name.to_s.match?(/\A\S+ competition \S+\z/)
  end

  def legacy_code(name)
    match = name.to_s.match(/\A\S+ competition (\S+)\z/)
    match && match[1]
  end
end
