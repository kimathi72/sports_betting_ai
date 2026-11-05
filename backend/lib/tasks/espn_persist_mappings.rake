# Persist verified ESPN team mappings for every configured competition.
#
# WRITES ExternalIdentifier rows only. It never touches Match, Season, Competition
# or Prediction. Refuses ambiguous identities and never overwrites an existing
# mapping (see Sync::EspnMappingPersister).
#
#   bundle exec rake espn:persist_mappings                 # all nine
#   bundle exec rake espn:persist_mappings CODES=SP1       # pilot
#   DRY_RUN=1 bundle exec rake espn:persist_mappings       # report only
namespace :espn do
  desc "Persist verified ESPN team mappings (CODES=SP1,D1 DRY_RUN=1)"
  task persist_mappings: :environment do
    codes = (ENV["CODES"] || "SP1 SC0 D1 I1 F1 N1 B1 P1 T1").split(/\s+|,/).reject(&:empty?)
    dry_run = ENV["DRY_RUN"] == "1"
    season_name = ENV.fetch("SEASON", Sync::SeasonWindow.current_label)
    client = Import::EspnClient.new

    puts "persist_mappings: #{codes.join(", ")} | season #{season_name}#{" | DRY RUN" if dry_run}"
    puts

    totals = Hash.new(0)
    codes.each do |code|
      begin
        plan = Sync::EspnCompetitionPlan.for_code(code, season_name: season_name)
        roster = client.teams(league: plan.slug).map { |e| e["team"] }
        identity = Import::EspnTeamIdentity.new(
          canonical: plan.canonical_clubs, provider_teams: roster,
          evidence: plan.evidence, existing_mappings: plan.existing_mappings,
        ).call

        if dry_run
          puts format("%-4s would create %-3d | ambiguous %-2d | unmapped %-2d",
                      code, identity[:matched].size, identity[:ambiguous].size, identity[:unmapped].size)
          next
        end

        result = Sync::EspnMappingPersister.new.call(code: code, identity: identity)
        totals[:created] += result.created
        totals[:already] += result.already_present
        totals[:skipped] += result.skipped_existing
        totals[:rejected] += result.rejected.size

        puts format("%-4s created=%-3d already=%-3d skipped=%-2d rejected=%-2d",
                    code, result.created, result.already_present,
                    result.skipped_existing, result.rejected.size)
      rescue StandardError => e
        # One competition failing must not stop the others, and must be visible.
        puts format("%-4s FAILED %s: %s", code, e.class.name.split("::").last, e.message[0, 80])
      end
    end

    unless dry_run
      puts
      puts "totals: created=#{totals[:created]} already=#{totals[:already]} " \
           "skipped=#{totals[:skipped]} rejected=#{totals[:rejected]}"
    end
  end
end
