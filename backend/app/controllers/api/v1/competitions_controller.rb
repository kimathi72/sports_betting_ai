module Api
  module V1
    # Read-only index of canonical competitions. Competitions are the top of the
    # football hierarchy, so this endpoint is the entry point for the mobile
    # client's competition list.
    #
    # Fields are ADDITIVE and stable. Provider identifiers are still not exposed:
    # they live in ExternalIdentifier and are resolved during imports, not by the
    # client.
    #
    # `seasons` and `match_count` were added because the mobile competition card and
    # the Home screen's activity summary need real numbers. They are computed with a
    # single aggregate query rather than one per competition, so the endpoint stays
    # one round trip however many competitions exist.
    #
    # `region` is derived from CompetitionCatalogue, the same source that supplies the
    # display name, so the mobile region filter groups by the same values the
    # data-import side uses. A competition outside the catalogue reports 'other'
    # rather than being hidden or guessed into a region.
    class CompetitionsController < ApplicationController
      def index
        stats = statistics
        competitions = Competition.order(:name, :id)

        render json: competitions.map { |competition| serialize(competition, stats[competition.id]) }
      end

      private

      def serialize(competition, stats)
        seasons = stats ? stats[:seasons] : []
        {
          id: competition.id,
          name: competition.name,
          code: competition.code,
          country: competition.country,
          region: CompetitionCatalogue.region_for(competition.code.presence || competition.name),
          seasons: seasons,
          current_season: seasons.max,
          match_count: stats ? stats[:match_count] : 0,
          completed_count: stats ? stats[:completed_count] : 0,
          team_count: stats ? stats[:team_count] : 0,
        }
      end

      # One query for every competition: season labels, match totals and the
      # completed split used by the Home activity summary.
      def statistics
        rows = Match.joins(:season)
                    .group("matches.competition_id", "seasons.name")
                    .pluck(
                      "matches.competition_id",
                      "seasons.name",
                      Arel.sql("COUNT(matches.id)"),
                      Arel.sql("COUNT(matches.id) FILTER (WHERE matches.status = 'completed')"),
                      Arel.sql("COUNT(DISTINCT matches.home_team_id) + COUNT(DISTINCT matches.away_team_id)")
                    )

        rows.each_with_object({}) do |(competition_id, season_name, total, completed, team_slots), memo|
          entry = memo[competition_id] ||= { seasons: [], match_count: 0, completed_count: 0, team_count: 0 }
          entry[:seasons] << season_name
          entry[:match_count] += total
          entry[:completed_count] += completed
          # This is an upper bound on distinct clubs (home and away counted
          # separately), which is exact for a league where every club plays at home
          # and away. It is labelled as a count of appearances in the JSON contract
          # documentation, not presented as a squad size.
          entry[:team_count] = [entry[:team_count], team_slots].max
        end.tap do |memo|
          memo.each_value { |entry| entry[:seasons] = entry[:seasons].uniq.sort }
        end
      end
    end
  end
end
