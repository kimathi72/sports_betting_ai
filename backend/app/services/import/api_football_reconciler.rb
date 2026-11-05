module Import
  # Applies normalised API-Football rows to the canonical tables.
  #
  # This is the only place the provider's data can write to Match. It is
  # deliberately conservative: when it cannot prove what a row means, it writes
  # nothing and says so. A rejected row is visible in the sync counts; a wrongly
  # written row corrupts training labels silently.
  #
  # IDENTITY RESOLUTION (in order)
  #   1. the provider fixture id, via ExternalIdentifier;
  #   2. otherwise, the same teams on the same calendar day.
  #
  # Step 2 exists because the historical dataset came from football-data.co.uk
  # before API-Football existed. Without it, every fixture already in the
  # database would be duplicated under a second identity.
  #
  # PRECEDENCE POLICY (when the two sources disagree)
  #   - A completed result is authoritative. A provider that later reports a
  #     different score, or a non-completed status, for an already-completed
  #     match is a conflict: the stored result is kept and the row is counted as
  #     `conflict`, never overwritten.
  #   - A kickoff time is provider-controlled: a confirmed reschedule updates it.
  #   - A live match never writes a score (enforced in the adapter as well, so a
  #     bug here cannot leak one).
  #
  # NOTE ON THE OUTCOME STRUCT: it is defined below the class on purpose.
  # Zeitwerk expects `import/api_football_reconciler.rb` to define only
  # `Import::ApiFootballReconciler`; a stray `Result` constant at module level
  # would shadow `Import::Result` (the import-run value object) whenever this
  # file happens to be autoloaded first. That produced a real, order-dependent
  # suite failure: `Import::Result.success` disappeared once any spec touched
  # this class. The struct is therefore not a module-level constant.
  class ApiFootballReconciler
    # Per-row outcome: :created, :updated, :skipped, :conflict or :rejected.
    # Nested (not a module-level `Import::Result`) so it can never shadow the
    # import-run value object; see the note above.
    Result = Struct.new(:kind, :match, keyword_init: true)

    # The reconciler is PROVIDER-AGNOSTIC. It resolves mappings through the
    # provider stated on the row, never a constant: the same class serves ESPN and
    # API-Football, and a hardcoded provider made every ESPN row unresolvable even
    # when its team was mapped.

    # Same-day tolerance when matching a fixture without a provider id. Two
    # fixtures between the same teams on one calendar day are the same match;
    # matching on the exact timestamp would fail on every provider reschedule.
    def apply_fixture(row, season:)
      return Result.new(kind: :rejected, match: nil) if row.nil? || row.status.nil?

      home_team = team_for(row.provider, row.home_provider_team_id)
      away_team = team_for(row.provider, row.away_provider_team_id)
      return Result.new(kind: :rejected, match: nil) if home_team.nil? || away_team.nil?

      match, mapped = resolve_match(row, home_team, away_team, season)
      return create_match(row, home_team, away_team, season) if match.nil?

      kind = reconcile(match, row)
      # Only record the provider identity once the row is known to be this match,
      # so a conflicting row does not silently claim the mapping.
      record_mapping(row, match) if mapped == false && kind != :conflict

      Result.new(kind: kind, match: match)
    rescue ActiveRecord::RecordNotUnique
      # Another run claimed the same provider id. The other run's work stands;
      # this row is a no-op rather than an error.
      Result.new(kind: :skipped, match: nil)
    end

    private

    def team_for(provider, provider_team_id)
      return nil if provider_team_id.blank?

      # Only an APPROVED mapping resolves a team. A proposed-but-unreviewed row
      # must never move a fixture, so it is invisible here.
      ExternalIdentifier.where(
        provider: provider, external_id: provider_team_id.to_s, review_state: "approved"
      ).first&.team
    end

    # Returns [match, mapped?]. `mapped` is true when the match was found
    # through a provider identifier.
    def resolve_match(row, home_team, away_team, season)
      mapping = ExternalIdentifier.find_by(
        provider: row.provider, external_id: row.provider_key,
      )
      return [mapping.match, true] if mapping&.match

      day_start = row.kickoff_at.beginning_of_day
      day_end = day_start + 1.day
      candidate = Match.where(
        home_team_id: home_team.id, away_team_id: away_team.id,
      ).where(kickoff_at: day_start...day_end).first

      [candidate, false]
    end

    # Mutates the match and returns the outcome kind.
    # The fixture is genuinely new. It is created, never merged into an existing
    # record, so an existing internal match id is untouchable from this path.
    def create_match(row, home_team, away_team, season)
      match = Match.create!(
        competition: season.competition,
        season: season,
        home_team: home_team,
        away_team: away_team,
        kickoff_at: row.kickoff_at,
        status: row.status,
        home_score: row.home_score,
        away_score: row.away_score
      )
      record_mapping(row, match)
      Result.new(kind: :created, match: match)
    end

    def reconcile(match, row)

      if match.status == "completed"
        return :skipped if same_result?(match, row)
        # A completed match with a different score, or reported as anything but
        # completed, is a source disagreement. The stored result wins.
        return :conflict unless row.status == "completed" && result_absent?(match)

        return :conflict unless scores_match?(match, row)

        return :skipped
      end

      return :conflict if row.status == "completed" && row.home_score.nil?

      changes = planned_changes(match, row)
      return :skipped if changes.empty?

      match.update!(changes)
      :updated
    end

    def result_absent?(match)
      match.home_score.nil? || match.away_score.nil?
    end

    def same_result?(match, row)
      return false if row.status != "completed"

      scores_match?(match, row)
    end

    def scores_match?(match, row)
      match.home_score == row.home_score && match.away_score == row.away_score
    end

    # Only fields the provider is authoritative for, and only when they differ.
    # The score is written exclusively for a completed, fully-scored row.
    def planned_changes(match, row)
      changes = {}

      if row.status != match.status
        changes[:status] = row.status
      end

      if row.kickoff_at && match.kickoff_at.to_i != row.kickoff_at.to_i
        changes[:kickoff_at] = row.kickoff_at
      end

      if row.status == "completed" && !row.home_score.nil? && !row.away_score.nil?
        changes[:home_score] = row.home_score
        changes[:away_score] = row.away_score
      end

      changes
    end

    def record_mapping(row, match)
      ExternalIdentifier.find_or_create_by!(
        provider: row.provider, external_id: row.provider_key,
      ) { |identifier| identifier.match = match }
    end
  end
end
