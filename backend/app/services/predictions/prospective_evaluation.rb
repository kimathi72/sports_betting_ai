module Predictions
  # Records the verified outcome against an issued prediction.
  #
  # TWO INVARIANTS
  # --------------
  # 1. The issued probabilities are never modified. The outcome goes into its own
  #    row, so the record of what we believed before kickoff stays intact even after
  #    the result is known.
  # 2. A prediction is scored at most once. The check is duplicated in Ruby (for a
  #    clear error) and in the database (for correctness under concurrency).
  class ProspectiveEvaluation
    class NotEligible < StandardError; end
    class AlreadyEvaluated < StandardError; end

    def initialize(eligibility: ProspectiveEligibility.new, protocol_digest: nil)
      @eligibility = eligibility
      @protocol_digest = protocol_digest
    end

    def call(prediction:)
      verdict = @eligibility.call(prediction)
      unless verdict.eligible?
        raise NotEligible,
              "prediction #{prediction.id} is not prospective evidence (#{verdict.reason})"
      end

      if ProspectiveEvaluationRecord.evaluated?(prediction.id)
        raise AlreadyEvaluated, "prediction #{prediction.id} has already been evaluated"
      end

      match = prediction.match
      outcome = actual_outcome(prediction, match)

      record = ProspectiveEvaluationRecord.new(
        prediction: prediction,
        match: match,
        market: prediction.market,
        actual_outcome: outcome,
        predicted_outcome: predicted_outcome(prediction),
        home_score: match.home_score,
        away_score: match.away_score,
        log_loss: log_loss(prediction, outcome),
        was_correct: predicted_outcome(prediction) == outcome,
        protocol_digest: @protocol_digest,
        evaluated_at: Time.current,
      )

      # The unique index turns a concurrent double-score into a validation error
      # rather than a second row.
      raise AlreadyEvaluated, "prediction #{prediction.id} has already been evaluated" unless record.save

      record
    end

    private

    # What actually happened, expressed in the same key space as the prediction's
    # outcome probabilities so the two can be compared directly.
    def actual_outcome(prediction, match)
      home = match.home_score
      away = match.away_score

      case prediction.market
      when "1x2"
        if home > away then "H" elsif home == away then "D" else "A" end
      when "btts"
        home.positive? && away.positive? ? "yes" : "no"
      when "over_under_2.5"
        (home + away) > 2.5 ? "over" : "under"
      when "double_chance"
        dc = if home > away then "1x" elsif home == away then %w[1x x2] else "x2" end
        # A draw satisfies two overlapping selections; recorded as the pair.
        dc.is_a?(Array) ? dc.join("/") : dc
      else
        # correct_score and anything else: the literal scoreline.
        "#{home}-#{away}"
      end
    end

    def normalised_outcomes(prediction)
      normalised(downcase: true, prediction: prediction)
    end

    # Outcome keys as stored, or folded for lookup. Distinct because comparison and
    # reporting need different normalisation.
    def normalised(downcase:, prediction:)
      raw = prediction.outcomes
      return {} unless raw.is_a?(Hash)

      return raw.transform_keys(&:to_s) unless downcase

      raw.transform_keys { |key| key.to_s.downcase }
    end

    def predicted_outcome(prediction)
      distribution = normalised_outcomes(prediction)
      return nil if distribution.empty?

      # Preserve the stored key's casing. `actual_outcome` returns the API's
      # canonical form ("H"/"D"/"A" for 1X2), so lower-casing here would make the
      # comparison in `was_correct` silently always false.
      normalised(downcase: false, prediction: prediction)
                              .max_by { |_key, value| value.to_f }&.first
    end

    def log_loss(prediction, outcome)
      probability = normalised_outcomes(prediction)[outcome.to_s.downcase]
      return nil if probability.nil?

      # Clipped so a confident error is a large finite penalty rather than infinity.
      clipped = [[probability.to_f, 1e-15].max, 1 - 1e-15].min
      -Math.log(clipped)
    end
  end
end
