module Api
  module V1
    # Read-only index of canonical seasons.
    #
    # WHY THIS EXISTS. A consumer (notably the ML training flow) must be able to
    # discover which seasons exist instead of hardcoding database ids. Ids are
    # not stable: re-importing history renumbers them, and a hardcoded list then
    # silently fetches the wrong data. Asking the API is the only durable option.
    #
    # Match counts are included deliberately. A client retrieving "all completed
    # matches" needs to know whether a season is complete or still in progress,
    # and the global match list is capped, so per-season retrieval is the safe
    # strategy. `completed_match_count` makes that decision possible without
    # guessing from the calendar.
    #
    # Ordering: competition, then season name DESCENDING, because season labels
    # are lexicographically sortable ("2025/26" > "2024/25") and the newest season
    # is what a caller usually wants first.
    class SeasonsController < ApplicationController
      def index
        seasons = Season.includes(:competition).order(:competition_id, name: :desc)

        seasons = seasons.where(competition_id: params[:competition_id]) if params[:competition_id].present?

        records = seasons.to_a
        counts = match_counts(records)
        completed = completed_counts(records)

        if ActiveModel::Type::Boolean.new.cast(params[:with_matches]) == true
          records = records.select { |season| counts.fetch(season.id, 0).positive? }
        end

        render json: records.map { |season| serialize(season, counts, completed) }
      end

      private

      # Two grouped queries rather than N+1 per season.
      def match_counts(seasons)
        return {} if seasons.empty?

        Match.where(season_id: seasons.map(&:id)).group(:season_id).count
      end

      def completed_counts(seasons)
        return {} if seasons.empty?

        Match.where(season_id: seasons.map(&:id), status: "completed").group(:season_id).count
      end

      def serialize(season, counts, completed)
        {
          id: season.id,
          name: season.name,
          competition_id: season.competition_id,
          match_count: counts.fetch(season.id, 0),
          completed_match_count: completed.fetch(season.id, 0),
        }
      end
    end
  end
end
