module Api
  module V1
    # Read-only index of canonical matches. A match is a fixture and, once
    # played, its final result, so this is the richest read payload in this
    # phase: it carries the competition, season and both teams by id, the kickoff
    # instant, the status and the final score when one exists.
    #
    # Ordering policy: kickoff time ascending, with the primary key as a
    # tie-breaker. Several fixtures legitimately share a kickoff instant (the
    # traditional 3pm Saturday slot), so a tie-breaker is required for the
    # payload to be stable. `kickoff_at` is NOT NULL in the schema, so there is
    # no null-ordering case to define here.
    #
    # Timestamps are serialised explicitly as UTC ISO 8601 rather than relying on
    # ActiveSupport's default JSON encoding, so the contract does not silently
    # change if the global encoder settings change.
    #
    # FILTERING AND LIMITS (additive; the response is still a bare JSON array):
    #
    #   ?competition_id=  restrict to one competition
    #   ?season_id=       restrict to one season (the common "current season" call)
    #   ?status=          one of scheduled, postponed, cancelled, in_progress,
    #                     completed; anything else is a 400, not an empty list
    #   ?limit=           1..MAX_LIMIT, applied AFTER ordering
    #
    # Filters exist because the imported corpus is large: the unfiltered response
    # was 717 KB / ~6s once every season was present, which is unusable on mobile
    # and makes "this season" inexpressible for the ML service. Requests without
    # parameters are unchanged, so this is not a breaking change.
    class MatchesController < ApplicationController
      # A deliberate cap. A client that needs more should page by season rather
      # than ask for the whole archive in one response.
      MAX_LIMIT = 2000
      DEFAULT_LIMIT = MAX_LIMIT

      def index
        filters = filter_params
        return if performed?

        limit = requested_limit
        return if performed?

        matches = Match.where(filters).order(:kickoff_at, :id).limit(limit)

        render json: matches.map { |match| serialize(match) }
      end

      private

      # Returns the ActiveRecord conditions, or nil after rendering a 400.
      def filter_params
        filters = {}

        filters[:competition_id] = integer_param(:competition_id)
        filters[:season_id] = integer_param(:season_id)
        return filters if performed?

        status = params[:status].presence
        if status
          unless Match::STATUSES.include?(status)
            render_error("status must be one of: #{Match::STATUSES.join(', ')}")
            return filters
          end
          filters[:status] = status
        end

        filters.compact
      end

      def integer_param(name)
        raw = params[name].presence
        return nil if raw.nil?

        Integer(raw, 10)
      rescue ArgumentError
        render_error("#{name} must be an integer")
        nil
      end


      # Returns the effective limit, or DEFAULT_LIMIT after rendering a 400. The
      # caller checks `performed?` and stops, because render does not terminate the
      # action — continuing would attempt a second render.
      def requested_limit
        raw = params[:limit].presence
        return DEFAULT_LIMIT if raw.nil?

        limit = Integer(raw, 10)
        return MAX_LIMIT if limit > MAX_LIMIT

        # Zero or negative would return nothing, which is never what a caller
        # means; treating it as an error surfaces the bug at the call site.
        if limit < 1
          render_error('limit must be a positive integer')
          return DEFAULT_LIMIT
        end

        limit
      rescue ArgumentError
        render_error('limit must be a positive integer')
        DEFAULT_LIMIT
      end

      def render_error(message)
        render json: { error: message }, status: :bad_request
      end

      def serialize(match)
        {
          id: match.id,
          competition_id: match.competition_id,
          season_id: match.season_id,
          home_team_id: match.home_team_id,
          away_team_id: match.away_team_id,
          kickoff_at: match.kickoff_at.utc.iso8601,
          status: match.status,
          home_score: match.home_score,
          away_score: match.away_score,
        }
      end
    end
  end
end
