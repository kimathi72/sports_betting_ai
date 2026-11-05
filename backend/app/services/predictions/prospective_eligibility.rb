module Predictions
  # Decides whether an issued prediction may be scored against a result.
  #
  # WHY EACH CHECK EXISTS
  # ---------------------
  # The database stores every prediction ever generated, including ones produced
  # after a match ended. Scoring those would yield an impressive and meaningless
  # accuracy. Each rejection below removes one way of accidentally doing that.
  #
  #   missing_issued_at           — no timestamp, so timing cannot be established
  #   issued_at_or_after_kickoff  — issued at or after kickoff: hindsight
  #   kickoff_changed_since_issue — the fixture moved: the prediction describes a
  #                                 different match than the one that finished
  #   missing_model_version       — provenance incomplete
  #   missing_feature_version     — provenance incomplete
  #   missing_freeze_digest       — provenance incomplete
  #   match_not_completed         — no verified result yet (includes postponed/
  #                                 cancelled: neither has a final score)
  #   missing_result              — completed but scores absent
  class ProspectiveEligibility
    Verdict = Struct.new(:eligible, :reason, keyword_init: true) do
      def eligible?
        eligible
      end
    end

    def call(prediction)
      match = prediction.match

      return reject(:missing_issued_at) if prediction.generated_at.nil?
      return reject(:match_missing) if match.nil?
      return reject(:missing_model_version) if prediction.model_version.blank?
      return reject(:missing_feature_version) if feature_version(prediction).blank?
      return reject(:missing_freeze_digest) if freeze_digest(prediction).blank?

      # Strictly before: a prediction timestamped exactly at kickoff is not
      # information available in advance.
      return reject(:issued_at_or_after_kickoff) unless prediction.generated_at < match.kickoff_at

      # The kickoff recorded at issue time must still match the fixture's kickoff.
      # A rescheduled match means the prediction was made about a different event.
      issued_kickoff = prediction.issued_kickoff_at
      if issued_kickoff.present? && issued_kickoff.to_i != match.kickoff_at.to_i
        return reject(:kickoff_changed_since_issue)
      end

      return reject(:match_not_completed) unless match.status == "completed"
      return reject(:missing_result) if match.home_score.nil? || match.away_score.nil?

      Verdict.new(eligible: true, reason: nil)
    end

    private

    def reject(reason)
      Verdict.new(eligible: false, reason: reason)
    end

    # `model_metadata` is a jsonb payload from the producer; a feature version may be
    # absent from older rows, in which case the prediction cannot be attributed.
    def feature_version(prediction)
      metadata = prediction.model_metadata
      return nil unless metadata.is_a?(Hash)

      metadata["feature_version"] || metadata[:feature_version]
    end

    def freeze_digest(prediction)
      return prediction.model_freeze_digest if prediction.model_freeze_digest.present?

      metadata = prediction.model_metadata
      return nil unless metadata.is_a?(Hash)

      metadata["model_freeze_digest"] || metadata[:model_freeze_digest]
    end
  end
end
