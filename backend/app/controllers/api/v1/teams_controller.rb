module Api
  module V1
    # Read-only index of canonical teams. Teams are identified independently of
    # competition or season, so this is a flat, unpaginated list at this stage.
    #
    # `normalized_name` is intentionally omitted from the payload. It is an
    # internal uniqueness key used to deduplicate provider spellings during
    # imports; exposing it would leak an implementation detail and invite clients
    # to depend on the normalization algorithm, which is free to change.
    class TeamsController < ApplicationController
      def index
        teams = Team.order(:name, :id)

        render json: teams.map { |team| serialize(team) }
      end

      private

      def serialize(team)
        {
          id: team.id,
          name: team.name,
          country: team.country,
        }
      end
    end
  end
end
