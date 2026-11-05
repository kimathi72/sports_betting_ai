module Sync
  # Runs identity discovery + reconciliation preview for many competitions at once.
  #
  # WHAT IT REPLACES
  # ----------------
  # Nine competitions each needing a bespoke script. This does the same work from a
  # list of codes, so adding a league is configuration.
  #
  # ISOLATION
  # ---------
  # Every competition is wrapped in its own rescue. A missing season, a provider
  # timeout or an unexpected exception produces a reported status for THAT
  # competition and the batch continues. There is no shared mutable state between
  # iterations, so one league cannot contaminate another's results.
  #
  # READ ONLY
  # ---------
  # Calls EspnClient (HTTP GET), EspnTeamIdentity (pure) and
  # Import::ReconciliationPreview (which never persists). Nothing is written.
  class EspnCoverageSurvey
    # codes: catalogue codes to survey.
    # season_name: internal season label ("2026/27").
    def initialize(client: Import::EspnClient.new,
                   identity_class: Import::EspnTeamIdentity,
                   preview: Import::ReconciliationPreview.new,
                   adapter: Import::EspnAdapter.new)
      @client = client
      @identity_class = identity_class
      @preview = preview
      @adapter = adapter
    end

    def call(codes:, season_name:, from_date:, to_date:)
      codes.each_with_object({}) do |code, results|
        results[code] = survey_one(code.to_s, season_name, from_date, to_date)
      end
    end

    private

    def survey_one(code, season_name, from_date, to_date)
      begin
        plan = EspnCompetitionPlan.for_code(code, season_name: season_name)
      rescue EspnCompetitionPlan::MissingSeason => e
        return { status: :missing_season, error: e.message }
      rescue EspnCompetitionPlan::Unsupported => e
        return { status: :unsupported, error: e.message }
      end

      begin
        survey_plan(plan, from_date, to_date)
      rescue Import::EspnClient::TransientError, Import::EspnClient::InvalidContentError => e
        { status: :provider_error, error: "#{e.class.name.split('::').last}: #{e.message}" }
      rescue StandardError => e
        # Reported, never swallowed: an unexpected failure in one league must be
        # visible rather than looking like an empty result.
        { status: :error, error: "#{e.class.name}: #{e.message}" }
      end
    end

    def survey_plan(plan, from_date, to_date)
      clubs = plan.canonical_clubs
      provider_teams = @client.teams(league: plan.slug).map { |entry| entry["team"] }

      identity = @identity_class.new(
        canonical: clubs,
        provider_teams: provider_teams,
        evidence: plan.evidence,
        existing_mappings: plan.existing_mappings
      ).call

      rows = @client.scoreboard_dates(league: plan.slug, from_date: from_date, to_date: to_date)
                   .events.filter_map { |payload| @adapter.normalize_fixture(payload) }

      # Evaluate the PROPOSED mappings, not just the ones already in the database.
      # Existing approved mappings are included too, so a competition that is partly
      # mapped previews exactly as an import would behave.
      team_index = identity[:existing].to_h { |e| [e[:provider_id], e[:canonical]] }
                                    .merge(identity[:matched].to_h { |m| [m[:provider_id], m[:canonical]] })

      preview = Import::ReconciliationPreview.new(team_index: team_index).call(rows, season: plan.season)

      {
        status: :ok,
        slug: plan.slug,
        season_id: plan.season.id,
        canonical_clubs: clubs.size,
        provider_teams: provider_teams.size,
        verified: identity[:matched].size,
        existing: identity[:existing].size,
        ambiguous: identity[:ambiguous].size,
        unmapped: identity[:unmapped].size,
        conflicts: identity[:conflicts].size,
        invalid: identity[:invalid].size,
        counts: preview.counts,
        unmatched_names: identity[:unmapped].map { |u| u[:provider_name] },
        ambiguous_names: identity[:ambiguous].map { |u| u[:provider_name] },
        proposals: identity[:matched].map do |m|
          { provider_id: m[:provider_id], provider_name: m[:provider_name],
            canonical: m[:canonical].name, basis: m[:basis] }
        end
      }
    end
  end
end
