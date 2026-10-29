# Requests 1X2 predictions for a set of fixtures, in the background.
#
# WHY QUEUED RATHER THAN SYNCHRONOUS
#
# A prediction call needs the ML service to be up and can take seconds per match.
# Running it inside an HTTP request would:
#   - tie a read endpoint to a second service's availability
#   - let any client trigger unbounded model work by refreshing
#   - turn a slow or dead model into a hung request instead of visible failed work
#
# The API therefore stays read-only and fast; this job owns inference. A future
# scheduler can enqueue it for upcoming fixtures without changing the contract.
#
# PARTIAL FAILURE IS NORMAL. One unreachable prediction must not discard the
# others, so the job continues through the batch and reports per-match outcomes.
# It raises only when nothing succeeded, which is what marks the job failed for
# the queue while keeping a partial batch useful.
#
# This job does NOT train anything. Training is the ML service's concern; a
# prediction request is a read-only call to an already-loaded model.
class PredictMatchesJob < ApplicationJob
  queue_as :predictions

  # Raised when the whole batch failed, so Sidekiq records a real failure.
  class AllPredictionsFailed < StandardError; end

  # What the batch produced. `skipped` holds ids that are not predictable (the
  # match is gone or already completed); they are not errors.
  Outcome = Struct.new(:succeeded, :failed, :skipped, keyword_init: true)

  def perform(match_ids)
    ids = Array(match_ids).map { |id| Integer(id) }
    outcome = Outcome.new(succeeded: [], failed: {}, skipped: [])

    # One query for the whole batch, so a large request does not do N lookups.
    found = Match.where(id: ids).includes(:competition, :season, :home_team, :away_team).to_a

    found.each do |match|
      if match.status == 'completed'
        # A result already exists; predicting it would be hindsight.
        outcome.skipped << match.id
        next
      end

      result = Predictions::Predictor.new.call(match)

      if result.success?
        outcome.succeeded << match.id
      else
        outcome.failed[match.id] = result.message
      end
    end

    # Ids that no longer exist are skipped, not failed: a deleted fixture is not
    # an error the caller can act on.
    outcome.skipped.concat(ids - found.map(&:id))

    log(outcome)

    raise AllPredictionsFailed, failure_summary(outcome) if outcome.succeeded.empty? && outcome.failed.any?

    outcome
  end

  private

  def log(outcome)
    Rails.logger.info(
      "PredictMatchesJob done succeeded=#{outcome.succeeded.length} " \
      "failed=#{outcome.failed.length} skipped=#{outcome.skipped.length}"
    )
  end

  # Only the first reason is logged: a dead ML service would otherwise write the
  # same line once per fixture.
  def failure_summary(outcome)
    first = outcome.failed.values.first
    "#{outcome.failed.length} prediction(s) failed; first: #{first}"
  end
end
