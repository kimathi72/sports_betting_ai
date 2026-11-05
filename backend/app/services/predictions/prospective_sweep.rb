module Predictions
  # Scores every eligible prediction whose match has finished NOW, using the
  # existing, already-reviewed evaluation gate.
  #
  # WHY THIS EXISTS
  # ---------------
  # `ProspectiveEvaluation` scores one prediction and enforces the full rules
  # (issued before kickoff, kickoff unchanged, digest present, result present,
  # scored at most once). Without a sweep, that gate is only ever exercised by
  # hand, and a fixture that finishes on a Sunday would sit unscored until
  # somebody remembered it. The sweep makes the evidence accumulate continuously
  # without weakening a single rule.
  #
  # WHAT IT DOES NOT DO
  # -------------------
  # - It does not create predictions. Issuing a prediction is a separate act that
  #   must happen BEFORE kickoff; deciding to predict a match that has already
  #   finished would be hindsight dressed as evidence.
  # - It does not retry indefinitely: a prediction that is refused is reported with
  #   its reason and left alone. Rejection reasons are evidence about the data, not
  #   errors to swallow.
  # - It never fabricates a result. Only `completed` matches with both scores are
  #   considered; every other match is simply not ready.
  #
  # RUNNING IT
  # ----------
  #   Predictions::ProspectiveSweep.new.call                # preview counts
  #   Predictions::ProspectiveSweep.new.call(apply: true)   # write the records
  #
  # Dry by default. A sweep that silently wrote to the evaluation table would make
  # "evaluate the backlog" impossible to do safely.
  class ProspectiveSweep
    Report = Struct.new(:evaluated, :refused, :pending, keyword_init: true) do
      def summary
        "evaluated=#{evaluated.size} refused=#{refused.size} pending=#{pending}"
      end

      def refused_reasons
        refused.group_by { |row| row[:reason] }.transform_values(&:size)
      end
    end

    def initialize(evaluation: ProspectiveEvaluation.new, eligibility: ProspectiveEligibility.new)
      @evaluation = evaluation
      @eligibility = eligibility
    end

    def call(apply: false)
      evaluated = []
      refused = []
      pending = 0

      candidates(include_unfinished: true).find_each do |prediction|
        verdict = @eligibility.call(prediction)
        unless verdict.eligible?
          if verdict.reason == :match_not_completed
            pending += 1
          else
            # Not merely "not ready": it will never become valid evidence (issued
            # late, rescheduled, no provenance). Reported so the gap is visible.
            refused << { prediction_id: prediction.id, match_id: prediction.match_id,
                         market: prediction.market, reason: verdict.reason }
          end
          next
        end

        next unless apply

        begin
          record = @evaluation.call(prediction: prediction)
          evaluated << { prediction_id: prediction.id, market: record.market,
                         actual: record.actual_outcome, correct: record.was_correct }
        rescue ProspectiveEvaluation::AlreadyEvaluated
          next
        rescue ProspectiveEvaluation::NotEligible => e
          refused << { prediction_id: prediction.id, match_id: prediction.match_id,
                       market: prediction.market, reason: e.message }
        end
      end

      # In preview mode nothing is written, so report what WOULD be evaluated
      # rather than an empty list that reads like "nothing to do".
      if apply == false
        evaluated = candidates.select { |p| @eligibility.call(p).eligible? }.map do |p|
          { prediction_id: p.id, match_id: p.match_id, market: p.market }
        end
      end

      Report.new(evaluated: evaluated, refused: refused, pending: pending)
    end

    private

    # Live (non-superseded) predictions that have not already been scored.
    # `include_unfinished` keeps genuinely-pending predictions visible as a count;
    # without it a report cannot distinguish "nothing to do" from "six matches
    # still to finish". Correctness is decided by the eligibility gate either way,
    # so this is a reporting choice, not a trust boundary.
    def candidates(include_unfinished: false)
      scope = Prediction.current
                        .where.not(id: ProspectiveEvaluationRecord.select(:prediction_id))

      scope = scope.joins(:match).where(matches: { status: "completed" })
                   .where.not(matches: { home_score: nil })
                   .where.not(matches: { away_score: nil }) unless include_unfinished

      scope.order(:id)
    end
  end
end
