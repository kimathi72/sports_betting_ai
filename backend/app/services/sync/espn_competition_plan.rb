module Sync
  # Everything needed to map and preview ONE ESPN competition.
  #
  # WHY A PLAN OBJECT
  # -----------------
  # Mapping, preview and (later) synchronization all need the same five facts:
  # which competition, which slug, which season, which clubs, which evidence. Passing
  # those around ad hoc is how the original per-league scripts diverged. One object,
  # built from configuration, keeps them together.
  #
  # CONFIGURATION, NOT CODE
  # -----------------------
  # The slug comes from EspnLeagueCoverage::VERIFIED, the clubs from the season's own
  # matches, and the evidence from EspnAliasEvidence. Adding a competition is a data
  # entry, not a new service.
  #
  # `code` is the catalogue code ("SP1"). `slug` is the provider's ("esp.1"). They are
  # never interchangeable, and that confusion is what caused the original E0/E1
  # contamination.
  class EspnCompetitionPlan
    class Unsupported < StandardError; end
    class MissingSeason < StandardError; end

    attr_reader :code, :slug, :competition, :season

    def self.for_code(code, season_name:)
      code = code.to_s
      slug = EspnLeagueCoverage.slug_for(code)
      if slug.nil?
        raise Unsupported,
              "#{code} has no verified ESPN fixture feed" \
              "#{EspnLeagueCoverage.unavailable_reason(code).then { |r| r ? " (#{r})" : "" }}"
      end

      competition = Competition.find_by(code: code)
      raise Unsupported, "competition #{code} does not exist locally" if competition.nil?

      season = Season.find_by(competition_id: competition.id, name: season_name.to_s)
      raise MissingSeason, "competition #{code} has no season named #{season_name.inspect}" if season.nil?

      new(code: code, slug: slug, competition: competition, season: season)
    end

    def initialize(code:, slug:, competition:, season:)
      @code = code
      @slug = slug
      @competition = competition
      @season = season
    end

    # Canonical clubs: every team that has played in this competition's season.
    #
    # Deliberately season-scoped rather than competition-wide. A club relegated three
    # seasons ago is not part of the current league, and mapping it would leave a
    # provider identity pointing at a team that cannot appear.
    def canonical_clubs
      ids = Match.where(season_id: season.id)
                 .pluck(:home_team_id, :away_team_id).flatten.uniq
      Team.where(id: ids).order(:name).to_a
    end

    # Provider display name => { canonical:, basis: }, for names that share no
    # lexical evidence with ours. Empty unless the competition has documented cases.
    def evidence
      EspnAliasEvidence.for(code)
    end

    # Existing approved ESPN team mappings for this competition's clubs, as
    # provider_team_id => canonical_team_id. Used to detect conflicts without
    # overwriting anything.
    def existing_mappings
      ExternalIdentifier.where(provider: "espn", team_id: canonical_clubs.map(&:id))
                        .pluck(:external_id, :team_id).to_h
    end

    def to_s
      "#{code} (#{slug}) #{season.name}"
    end
  end
end
