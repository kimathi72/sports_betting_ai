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
    class MatchesController < ApplicationController
      def index
        matches = Match.order(:kickoff_at, :id)

        render json: matches.map { |match| serialize(match) }
      end

      private

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
