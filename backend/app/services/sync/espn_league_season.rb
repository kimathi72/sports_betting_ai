module Sync
  # Resolves the internal Season an ESPN league's fixtures belong to.
  #
  # THE DEFECT THIS REPLACES
  # ------------------------
  # ESPN entry points resolved the target season with `Season.find_by(name: label)`.
  # Season names are NOT unique across competitions — every competition has a
  # "2026/27" — so the lookup returned whichever row the database offered first,
  # in practice the Premier League's. `espn:discover[eng.2,"2026/27"]` consequently
  # wrote Championship fixtures into the Premier League's season (139 rows in the
  # live database), and `espn:ingest` had the identical defect.
  #
  # THE RULE
  # --------
  # The provider knows a league by its SLUG ("eng.1"), because that is what the
  # operator types and what the discovery job iterates. Resolution therefore goes:
  #
  #   slug --EspnLeagueCoverage::VERIFIED--> catalogue code --Competition--> Season
  #
  # Every step is a lookup on an identity, never on a display name:
  #   - the slug maps to exactly one code through a frozen constant;
  #   - the code maps to exactly one Competition (unique index on `code`);
  #   - the season is then scoped to that competition, so a season belonging to
  #     another competition can never be returned, whatever the label.
  #
  # FAILING LOUDLY
  # --------------
  # An unresolved season raises instead of returning nil. A caller that silently
  # imports nothing is indistinguishable from one whose import found no fixtures,
  # which is precisely how the original defect stayed invisible for two runs: the
  # ledger recorded successful imports the whole time.
  #
  # `find` retains the older nil-returning contract for callers that treat "no
  # season for this league yet" as an ordinary skip (the scheduled discovery job).
  class EspnLeagueSeason
    # The slug is not a league ESPN publishes, or is not one we have mapped.
    class UnknownLeague < StandardError; end

    # The league is known but this database has no such competition.
    class UnknownCompetition < StandardError; end

    # The label is blank or not a recognisable season name.
    class UnknownSeason < StandardError; end

    # More than one season answers to this label within the competition.
    class AmbiguousSeason < StandardError; end

    # ESPN league slug -> internal Season.
    #
    #   for_league("eng.2", "2026/27")  => the Championship's 2026/27 season
    #
    # Raises UnknownLeague / UnknownCompetition / UnknownSeason / AmbiguousSeason.
    def self.for_league(slug, label)
      # VERIFIED is keyed CODE => SLUG, so the inverse lookup is the one that
      # applies here. Reading it as VERIFIED[slug] silently missed every league.
      code = EspnLeagueCoverage.code_for_slug(slug)
      if code.nil?
        raise UnknownLeague,
              "#{slug.inspect} is not a mapped ESPN league; known slugs: " \
              "#{EspnLeagueCoverage::VERIFIED.values.sort.join(', ')}"
      end

      for_code(code, label)
    end

    # Catalogue code -> internal Season. Same failures as `for_league`.
    def self.for_code(code, label)
      competition = Competition.find_by(code: code.to_s)
      raise UnknownCompetition, "no Competition with code #{code.to_s.inspect}" if competition.nil?
      raise UnknownSeason, "season label is blank for competition #{code}" if label.blank?

      season = single_season(competition, label.to_s)
      raise UnknownSeason,
            "competition #{code} (#{competition.name}) has no season named #{label.to_s.inspect}" if season.nil?

      season
    end

    # Compatibility wrapper: the competition-scoped season, or nil when this
    # competition has none. Never returns another competition's season.
    #
    # Used by the scheduled discovery job, where a league without a current season
    # is a normal, reportable skip rather than an error.
    def self.find(code, label)
      competition = Competition.find_by(code: code.to_s)
      return nil if competition.nil? || label.blank?

      single_season(competition, label.to_s)
    end

    # Scoped lookup. A label that matches more than one season is a data defect we
    # refuse to resolve, because choosing one would recreate exactly the silent
    # mis-selection this class exists to prevent.
    def self.single_season(competition, label)
      matches = Season.where(competition_id: competition.id, name: label).limit(2).to_a
      if matches.size > 1
        raise AmbiguousSeason,
              "#{matches.size} seasons are named #{label.inspect} for competition " \
              "#{competition.code}: ids #{matches.map(&:id).join(', ')}"
      end

      matches.first
    end

    private_class_method :single_season
  end
end
