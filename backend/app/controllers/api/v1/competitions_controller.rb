module Api
  module V1
    # Read-only index of canonical competitions. Competitions are the top of the
    # football hierarchy, so this endpoint is the entry point for the mobile
    # client's competition list.
    #
    # The response is deliberately minimal and stable: only the public identity
    # and display fields are exposed, in a deterministic order. Provider-specific
    # identifiers are NOT exposed here; they live in ExternalIdentifier and are
    # resolved during imports, not by the client.
    class CompetitionsController < ApplicationController
      # Ordered by name, with the primary key as a tie-breaker so the payload is
      # stable across requests even if two rows were ever to share a name.
      def index
        competitions = Competition.order(:name, :id)

        render json: competitions.map { |competition| serialize(competition) }
      end

      private

      def serialize(competition)
        {
          id: competition.id,
          name: competition.name,
          code: competition.code,
          country: competition.country,
        }
      end
    end
  end
end
