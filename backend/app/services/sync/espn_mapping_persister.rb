module Sync
  # Persists verified ESPN team mappings for one competition.
  #
  # SCOPE IS THE COMPETITION
  # ------------------------
  # A mapping is only written for a club that actually plays in the stated
  # competition's season. That is what stops a Barcelona mapping being created while
  # processing the Bundesliga — the class of error that put Championship fixtures
  # into the Premier League.
  #
  # REFUSALS
  #   - ambiguous / unmapped identities are never written (only `matched`);
  #   - an existing mapping is never overwritten, even if the new proposal differs;
  #   - a club outside the competition is rejected and reported.
  #
  # IDEMPOTENT: a provider id already mapped to the same club counts as
  # `already_present` and writes nothing, so reruns are safe.
  class EspnMappingPersister
    Result = Struct.new(:competition_code, :created, :already_present, :skipped_existing,
                        :rejected, keyword_init: true)

    def call(code:, identity:)
      plan = EspnCompetitionPlan.for_code(code, season_name: Sync::SeasonWindow.current_label)
      allowed_team_ids = plan.canonical_clubs.map(&:id).to_set

      created = 0
      already = 0
      skipped = 0
      rejected = []

      ActiveRecord::Base.transaction do
        Array(identity[:matched]).each do |m|
          provider_id = m[:provider_id].to_s
          team = m[:canonical]

          unless team && allowed_team_ids.include?(team.id)
            rejected << provider_id
            next
          end

          existing = ExternalIdentifier.find_by(provider: "espn", external_id: provider_id)
          if existing
            if existing.team_id == team.id
              # Already mapped to the right club; ensure it is trusted.
              existing.update!(review_state: "approved") unless existing.review_state == "approved"
              already += 1
            else
              skipped += 1
            end
            next
          end

          record = ExternalIdentifier.new(provider: "espn", external_id: provider_id,
                                          team: team, review_state: "approved")
          if record.save
            created += 1
          else
            rejected << provider_id
          end
        end
      end

      Result.new(competition_code: plan.code, created: created, already_present: already,
                 skipped_existing: skipped, rejected: rejected)
    rescue EspnCompetitionPlan::MissingSeason, EspnCompetitionPlan::Unsupported => e
      raise Unsupported, e.message
    end

    class Unsupported < StandardError; end
  end
end
