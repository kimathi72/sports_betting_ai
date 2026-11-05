module Sync
  # Finds — and on request removes — ESPN fixtures that were filed into a season
  # they do not belong to.
  #
  # WHAT HAPPENED
  # -------------
  # `espn:discover[<slug>,<SEASON>]` resolved the target Season BY NAME. Several
  # competitions share a season name (they always do), so the lookup returned the
  # Premier League's season and another league's fixtures were written into it
  # under competition E0. The cause is fixed in Sync::EspnLeagueSeason; this
  # repairs rows already written (407 scheduled and 29 bogus completed in the live
  # database at the time of writing).
  #
  # WHY THE SIGNATURE IS ABOUT IMPOSSIBLE ROWS
  # ------------------------------------------
  # Date and club do not distinguish a bled row: ESPN's dates fall inside the
  # season window, and promoted/relegated clubs appear in both divisions, so any
  # test on those either misses the bleed or removes real fixtures (both were
  # measured on the live data).
  #
  # What cannot be real is:
  #   1. a kickoff at an hour no European league plays (the fixture data is
  #      restricted to plausible slots; 02:00–04:00 UTC is not one of them), or
  #   2. a `completed` row whose kickoff is still in the future — a result cannot
  #      exist for a match that has not been played.
  #
  # Both are facts about the row itself. Together with the provenance conditions
  # below, they cannot match a genuine fixture.
  #
  # REQUIRED PROVENANCE (all candidates)
  #   - an ESPN identifier, and
  #   - NO football-data identifier: the canonical history import is out of scope
  #     by construction, so the training data cannot be touched.
  class ForeignFixtureBleed
    # Raised by `call` so the removal path cannot be reached by accident.
    class Retired < StandardError; end

    PROVIDER = Import::EspnAdapter::PROVIDER
    TRUSTED_PROVIDER = 'football_data'.freeze

    def initialize(season)
      @season = season
    end

    def self.candidates(season)
      new(season).candidates
    end

    def candidates
      Match.where(season_id: season.id)
           .where(status: %w[scheduled postponed cancelled completed])
           .includes(:home_team, :away_team)
           .select { |match| candidate?(match) }
    end

    # Removes the candidates and their ESPN identity, in one transaction.
    #
    # RETIRED: this path is unreachable. The classifier below does not describe
    # the confirmed contamination (see the note in `candidates`), so deleting on
    # it would be a speculative repair of real football data.
    def call(*)
      raise Retired,
            'Sync::ForeignFixtureBleed is retired: its classifier does not describe ' \
            'the confirmed contamination. Repair affected rows by reassigning ' \
            'competition/season with provider evidence (handout §8.7).'
    end

    private

    attr_reader :season

    def candidate?(match)
      return false if match.kickoff_at.nil?
      return false unless espn_provenance?(match)
      return false if trusted_provenance?(match)

      completed_before_kickoff?(match)
    end

    # A result for a match that has not kicked off yet: the one rule that
    # identifies this bleed. No genuine row can satisfy it, and it is independent
    # of league names, clubs and date ranges — all of which failed to discriminate
    # on the live data.
    def completed_before_kickoff?(match)
      match.status == 'completed' && match.kickoff_at > Time.current
    end

    def espn_provenance?(match)
      ExternalIdentifier.exists?(provider: PROVIDER, match_id: match.id)
    end

    def trusted_provenance?(match)
      ExternalIdentifier.exists?(provider: TRUSTED_PROVIDER, match_id: match.id)
    end
  end
end
