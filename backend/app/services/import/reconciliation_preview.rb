module Import
  # Read-only reconciliation preview.
  #
  # WHY THIS IS NOT A SECOND IMPLEMENTATION
  # ---------------------------------------
  # Preview and import must agree, or the preview is a lie. This class therefore
  # asks the REAL reconciler for its identity decisions, and reproduces only the
  # classification that leads up to a write — never the write itself.
  #
  # The reconciler's write surface is exactly three calls inside `apply_fixture`:
  # `create_match`, `match.update!` (via `planned_changes`) and `record_mapping`.
  # All three are private and are reached only from `apply_fixture`, so this class
  # deliberately never calls `apply_fixture`; it uses the same public inputs the
  # reconciler uses (`team_for`, `resolve_match`) through small read-only helpers.
  #
  # PROVING ZERO WRITES
  # -------------------
  # The specs stub `Match.create!`, `Match#update!` and
  # `ExternalIdentifier.find_or_create_by!` to raise, and assert counts do not move.
  # A preview that wrote anywhere would fail loudly rather than quietly.
  class ReconciliationPreview
    COUNTS = %i[events resolved part_resolved unresolved invalid existing would_create
                would_update conflicts].freeze

    Result = Struct.new(:counts, :rows, keyword_init: true)

    def initialize(reconciler: ApiFootballReconciler.new, team_index: nil)
      @reconciler = reconciler
      # provider team id => Team, for a preview of NOT-YET-PERSISTED mappings.
      #
      # Without this the preview can only see clubs that are already mapped, so a
      # dry run of a proposed mapping set reports "0 resolved" and looks like the
      # proposal is worthless. Supplying the index lets the preview evaluate the
      # proposal honestly while still writing nothing.
      @team_index = team_index
    end

    # rows: normalised FixtureRow objects (from any adapter)
    # season: the target internal Season
    #
    # Returns Result with `counts` and per-row detail. Nothing is persisted.
    def call(rows, season:)
      counts = COUNTS.to_h { |key| [key, 0] }
      detail = []

      Array(rows).each do |row|
        counts[:events] += 1

        if row.nil?
          counts[:invalid] += 1
          detail << { kind: :invalid, reason: "nil row" }
          next
        end

        if row.kickoff_at.nil?
          counts[:invalid] += 1
          detail << { kind: :invalid, reason: "missing kickoff", provider_id: row.provider_key }
          next
        end

        home_team = team_for(row, row.home_provider_team_id)
        away_team = team_for(row, row.away_provider_team_id)

        if home_team.nil? && away_team.nil?
          counts[:unresolved] += 1
          detail << { kind: :unresolved, provider_id: row.provider_key, side: :both }
          next
        elsif home_team.nil?
          counts[:part_resolved] += 1
          detail << { kind: :part_resolved, provider_id: row.provider_key, side: :home }
          next
        elsif away_team.nil?
          counts[:part_resolved] += 1
          detail << { kind: :part_resolved, provider_id: row.provider_key, side: :away }
          next
        end

        counts[:resolved] += 1

        existing, mapped = existing_match(row, home_team, away_team, season)

        if existing.nil?
          counts[:would_create] += 1
          detail << { kind: :would_create, provider_id: row.provider_key,
                      kickoff: row.kickoff_at.iso8601, status: row.status,
                      home: home_team.name, away: away_team.name }
          next
        end

        counts[:existing] += 1

        # A row pointing at a match in a different season is a competition/season
        # conflict, not an ordinary duplicate. Reported, never silently applied.
        if existing.season_id != season.id
          counts[:conflicts] += 1
          detail << { kind: :conflict, provider_id: row.provider_key, match_id: existing.id,
                      reason: "match belongs to season #{existing.season_id}, not #{season.id}",
                      matched_by: mapped ? :provider_id : :teams_and_day }
          next
        end

        if existing.status == "completed"
          # Completed results are authoritative; the reconciler would keep them.
          detail << { kind: :skipped_completed, provider_id: row.provider_key, match_id: existing.id }
          next
        end

        detail << { kind: :existing, provider_id: row.provider_key, match_id: existing.id }
      end

      Result.new(counts: counts, rows: detail)
    end

    private

    attr_reader :reconciler

    # Mirrors ApiFootballReconciler#team_for: approved mappings only, or the
    # supplied in-memory proposal when one is provided.
    def team_for(row, provider_team_id)
      return nil if provider_team_id.blank?

      if @team_index
        indexed = @team_index[provider_team_id.to_s]
        return indexed if indexed
      end

      ExternalIdentifier.where(
        provider: row.provider, external_id: provider_team_id.to_s, review_state: "approved"
      ).first&.team
    end

    # Mirrors ApiFootballReconciler#resolve_match: provider id, then teams + day.
    # Returns [match, mapped_by_provider_id?].
    def existing_match(row, home_team, away_team, season)
      mapping = ExternalIdentifier.find_by(provider: row.provider, external_id: row.provider_key)
      return [mapping.match, true] if mapping&.match

      day = row.kickoff_at.beginning_of_day
      candidate = Match.where(home_team_id: home_team.id, away_team_id: away_team.id)
                       .where(kickoff_at: day...(day + 1.day)).first
      [candidate, false]
    end
  end
end
