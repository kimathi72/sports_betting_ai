module Api
  module V1
    # Reports which model versions have produced stored predictions, and how
    # recently.
    #
    # HONEST EMPTY STATE. Before any prediction exists this returns zero and empty
    # lists rather than an error or fabricated numbers. A client can then show
    # "no predictions yet" instead of guessing.
    #
    # This endpoint reports what RAILS has stored. It does not ask the ML service
    # whether a model is loaded: that would make this endpoint fail whenever the
    # ML container is down, and would blur "we have predictions" with "the model
    # server is up". A separate ML-side /health covers the latter.
    class ModelStatusController < ApplicationController
      def show
        predictions = Prediction.all

        render json: {
          prediction_count: predictions.count,
          latest_generated_at: predictions.maximum(:generated_at)&.utc&.iso8601,
          model_versions: model_versions(predictions),
        }
      end

      private

      # One entry per version, newest first, with the span of predictions it has
      # produced. This is what makes a model's footprint auditable.
      def model_versions(predictions)
        predictions.group(:model_version)
                   .pluck(:model_version,
                          Arel.sql("COUNT(*)"),
                          Arel.sql("MIN(generated_at)"),
                          Arel.sql("MAX(generated_at)"))
                   .map do |version, count, first_at, last_at|
          {
            model_version: version,
            prediction_count: count,
            first_generated_at: first_at&.utc&.iso8601,
            latest_generated_at: last_at&.utc&.iso8601,
          }
        end
                   .sort_by { |entry| entry[:latest_generated_at].to_s }
                   .reverse
      end
    end
  end
end
