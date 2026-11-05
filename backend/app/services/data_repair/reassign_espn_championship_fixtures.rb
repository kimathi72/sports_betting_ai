module DataRepair
  # Reassigns Championship fixtures that were filed under the Premier League.
  #
  # WHAT IT REPAIRS
  # ---------------
  # `espn:discover` once resolved the target season by NAME. Season names are not
  # unique across competitions, so `eng.2` fixtures were written into E0's 2026/27
  # season. This moves them to E1's 2026/27 season.
  #
  # HOW THE AFFECTED ROWS ARE IDENTIFIED
  # ------------------------------------
  # By PROVIDER EVIDENCE — the ESPN event id — and nothing else. The three obvious
  # alternatives were measured against the live database and all three are wrong:
  #
  #   * database id range: the range recorded in the handover (39676..39787)
  #     contains only 112 of the affected rows, not all of them;
  #   * kickoff dates: the rows fall inside the season window like real fixtures;
  #   * club membership: promoted/relegated clubs appear in both divisions.
  #
  # ESPN serves `40187xxxxxx` events from `eng.1` and `40188xxxxxx` from `eng.2`.
  # A row carrying a `40188` id, filed under E0, whose clubs played in E1, is a
  # Championship fixture in the wrong competition. That is the whole rule.
  #
  # WHAT IT CHANGES
  # ---------------
  # competition_id and season_id ONLY. Teams, kickoff, status, scores and the ESPN
  # identifier are untouched — the rows are moved, never rewritten.
  #
  # WHAT IT REFUSES TO TOUCH
  # ------------------------
  #   * completed results, unless explicitly included (see `include_completed:`);
  #     the conservative default leaves them for a reviewed second step;
  #   * any row with football_data provenance — the canonical history is not ours
  #     to move, and a row that has it is not an ESPN-only import;
  #   * any row whose clubs never played in the target competition.
  #
  # SAFETY
  # ------
  # - Refuses to run in production.
  # - Asserts the exact expected row count unless a caller overrides it.
  # - Asserts every row's current competition/season before writing anything.
  # - Updates inside a transaction and verifies the affected row count.
  # - Returns a token recording the original values, for `rollback!`.
  class ReassignEspnChampionshipFixtures
    class GuardFailed < StandardError; end

    SOURCE_CODE = 'E0'.freeze
    DESTINATION_CODE = 'E1'.freeze
    SEASON_NAME = '2026/27'.freeze

    # ESPN event-id prefixes. Verified against the live scoreboard: an event id
    # beginning 40187 is returned by eng.1, 40188 by eng.2.
    CHAMPIONSHIP_ID_PREFIX = '40188'.freeze
    PREMIER_ID_PREFIX = '40187'.freeze

    Result = Struct.new(:updated, :ids, :token, keyword_init: true)

    attr_reader :last_repair_token

    def initialize(expected_count: nil, include_completed: true)
      @expected_count = expected_count
      @include_completed = include_completed
    end

    def source_competition
      @source_competition ||= Competition.find_by(code: SOURCE_CODE) ||
                              raise(GuardFailed, "no competition #{SOURCE_CODE}")
    end

    def destination_competition
      @destination_competition ||= Competition.find_by(code: DESTINATION_CODE) ||
                                   raise(GuardFailed, "no competition #{DESTINATION_CODE}")
    end

    def source_season
      @source_season ||= Season.find_by(competition_id: source_competition.id, name: SEASON_NAME) ||
                         raise(GuardFailed, "no #{SEASON_NAME} season for #{SOURCE_CODE}")
    end

    def destination_season
      @destination_season ||= Season.find_by(competition_id: destination_competition.id, name: SEASON_NAME) ||
                              raise(GuardFailed, "no #{SEASON_NAME} season for #{DESTINATION_CODE}")
    end

    # The rows this repair would move. Read-only; safe to call for a preview.
    def affected_ids
      scope.pluck(:id).sort
    end

    def call
      guard_environment!
      guard_destination!

      ids = affected_ids
      guard_expected_count!(ids)
      guard_sources!(ids)

      token = ids.to_h { |id| [id, [source_competition.id, source_season.id]] }

      updated = 0
      Match.transaction do
        updated = Match.where(id: ids).where(
          competition_id: source_competition.id, season_id: source_season.id
        ).update_all(
          competition_id: destination_competition.id,
          season_id: destination_season.id,
          updated_at: Time.current
        )

        # Inside the transaction: a mismatch rolls everything back rather than
        # leaving a half-applied repair behind.
        unless updated == ids.size
          raise GuardFailed,
                "updated #{updated} row(s) but #{ids.size} were selected; rolled back"
        end
      end

      @last_repair_token = token
      Result.new(updated: updated, ids: ids, token: token)
    end

    # Restores exactly the rows this repair moved, and nothing else.
    #
    # Requires the token returned by `call`. A row that has since changed
    # competition/season by another route is left alone and reported, because
    # silently overwriting a later legitimate change is worse than an incomplete
    # rollback.
    def rollback!(token = @last_repair_token)
      raise GuardFailed, 'no repair token to roll back' if token.nil?

      restored = 0
      skipped = []
      Match.transaction do
        token.each do |id, (competition_id, season_id)|
          rows = Match.where(id: id,
                             competition_id: destination_competition.id,
                             season_id: destination_season.id)
          if rows.update_all(competition_id: competition_id, season_id: season_id,
                             updated_at: Time.current) == 1
            restored += 1
          else
            skipped << id
          end
        end
      end

      { restored: restored, skipped: skipped }
    end

    private

    def scope
      Match.where(competition_id: source_competition.id, season_id: source_season.id)
           .where(status: include_completed? ? %w[scheduled completed] : ['scheduled'])
           .where(id: espn_championship_match_ids)
           .where(id: championship_club_match_ids)
           .where.not(id: football_data_match_ids)
    end

    def include_completed?
      @include_completed
    end

    def espn_championship_match_ids
      ExternalIdentifier.where(provider: 'espn')
                        .where('external_id LIKE ?', "#{CHAMPIONSHIP_ID_PREFIX}%")
                        .select(:match_id)
    end

    # Matches that already carry canonical football-data provenance.
    #
    # `.where.not(match_id: nil)` is NOT optional. football_data identifiers are
    # also used for TEAM mappings, and 469 of them have a NULL match_id. Since
    # `SELECT match_id` then yields NULLs, `id NOT IN (... , NULL)` evaluates to
    # NULL for every row and the filter matches NOTHING — which silently disabled
    # the entire exclusion and made this repair select zero rows. Measured, not
    # theorised.
    def football_data_match_ids
      ExternalIdentifier.where(provider: 'football_data')
                        .where.not(match_id: nil)
                        .select(:match_id)
    end

    # Matches involving at least one club with completed Championship history.
    # "Championship club" is defined by results, not by names or geography.
    def championship_club_match_ids
      club_ids = Match.completed.where(competition_id: destination_competition.id)
                     .pluck(:home_team_id, :away_team_id).flatten.uniq
      Match.where(home_team_id: club_ids).or(Match.where(away_team_id: club_ids)).select(:id)
    end

    def guard_environment!
      if Rails.env.production?
        raise GuardFailed, 'refusing to run a data repair in production'
      end
    end

    def guard_destination!
      if destination_season.competition_id != destination_competition.id
        raise GuardFailed,
              "destination season #{destination_season.id} does not belong to #{DESTINATION_CODE}"
      end
      if destination_season.id == source_season.id
        raise GuardFailed, 'source and destination seasons are identical'
      end
    end

    def guard_expected_count!(ids)
      return if @expected_count.nil?
      return if ids.size == @expected_count

      raise GuardFailed,
            "expected #{@expected_count} affected row(s) but found #{ids.size}; " \
            'the database does not match the verified preflight'
    end

    # Every selected row must still be in the expected source competition/season.
    def guard_sources!(ids)
      rows = Match.where(id: ids).pluck(:id, :competition_id, :season_id)
      wrong = rows.reject do |_id, competition_id, season_id|
        competition_id == source_competition.id && season_id == source_season.id
      end
      return if wrong.empty?

      raise GuardFailed,
            "#{wrong.size} row(s) are not in expected source #{SOURCE_CODE}/#{SEASON_NAME}: " \
            "#{wrong.first(5).map(&:first).join(', ')}"
    end
  end
end
