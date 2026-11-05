# Maps ESPN team ids onto canonical teams for the competitions whose results we
# already hold, so upcoming fixtures from ESPN can be reconciled.
#
# WHY THIS IS SEPARATE FROM `espn:map_teams`
# ------------------------------------------
# `espn:map_teams` prints `unmapped` as a free-text list and writes nothing for
# those teams, so it can never reach a decision on names that differ from ours
# (`Man City` vs `Manchester City`). This task resolves a candidate, records it
# as a PENDING proposal, and leaves it to a human-facing review before it is
# trusted as an authoritative mapping.
#
# HOW A CANDIDATE IS CHOSEN
# -------------------------
#   1. exact match on Team.normalize (the same key the importer uses);
#   2. otherwise, the only team of that competition whose normalized name
#      contains the provider's normalized name, or is contained by it.
#
# Step 2 is a containment test on normalised names, NOT fuzzy scoring: it either
# yields exactly one candidate or none. Several candidates means ambiguous and
# nothing is written. That is stricter than a similarity threshold and it cannot
# silently merge two clubs.
#
# SCOPE SAFETY
# ------------
# A candidate must belong to a season of the competition the league feeds. ESPN
# league slugs map to our catalogue codes by hand (LEAGUE_MAP) rather than by
# guessing, because eng.2 and esp.2 are both "second divisions" and a wrong slug
# would map a club from the wrong country.
#
# Nothing here writes a Match. Pending rows are informational until promoted.
namespace :espn do
  # ESPN league slug -> internal competition code. Verified one at a time against
  # the live ESPN teams endpoint (each returned the expected clubs) before being
  # added; competitions whose slug has not been verified are deliberately absent.
  LEAGUE_MAP = {
    "eng.1" => "E0",
    "eng.2" => "E1",
    "eng.5" => "EC",
    "sco.1" => "SC0",
    "sco.2" => "SC1",
    "esp.1" => "SP1",
    "esp.2" => "SP2",
    "ger.1" => "D1",
    "ger.2" => "D2",
    "ita.1" => "I1",
    "ita.2" => "I2",
    "fra.1" => "F1",
    "fra.2" => "F2",
    "ned.1" => "N1",
    "bel.1" => "B1",
    "por.1" => "P1",
    "tur.1" => "T1",
    "gre.1" => "G1"
  }.freeze

  desc "Propose ESPN team mappings for one league or all mapped leagues (DRY_RUN=1, LEAGUE=eng.2)"
  task :propose_team_mappings => :environment do
    dry_run = ENV["DRY_RUN"] == "1"
    leagues = ENV["LEAGUE"] ? [ENV["LEAGUE"]] : LEAGUE_MAP.keys
    client = Import::EspnClient.new
    resolver = Import::EspnTeamResolver.new

    leagues.each do |league|
      code = LEAGUE_MAP[league]
      if code.nil?
        puts "#{league}: no catalogue mapping; skipped (add it to LEAGUE_MAP after verifying)"
        next
      end

      competition = Competition.find_by(code: code)
      if competition.nil?
        puts "#{league} (#{code}): competition not present locally; skipped"
        next
      end

      # Only teams that have ever played in this competition are candidates:
      # resolving "Sheffield United" against every club in the database could
      # reach a namesake in another country.
      season_ids = Season.where(competition_id: competition.id).select(:id)
      team_ids = Match.where(season_id: season_ids).pluck(:home_team_id, :away_team_id).flatten.uniq
      ours = Team.where(id: team_ids).to_a

      stats = Hash.new(0)
      (client.teams(league: league) rescue []).each do |entry|
        team = entry["team"]
        provider_id = team["id"].to_s
        display = team["displayName"].to_s

        if ExternalIdentifier.exists?(provider: "espn", external_id: provider_id, team_id: nil)
          stats[:already_proposed] += 1
          next
        end
        if ExternalIdentifier.exists?(provider: "espn", external_id: provider_id)
          stats[:already_mapped] += 1
          next
        end

        candidate = resolver.resolve(display, ours)
        if candidate.is_a?(Symbol)
          stats[candidate] += 1
          next
        end

        record = ExternalIdentifier.new(provider: "espn", external_id: provider_id,
                                        team: candidate, review_state: "pending")
        if dry_run
          puts "  WOULD MAP #{display} -> #{candidate.name}"
        elsif record.save
          stats[:proposed] += 1
        else
          stats[:error] += 1
          puts "  ERROR #{display}: #{record.errors.full_messages.join(', ')}"
        end
      end

      puts "#{league} (#{code}): #{stats.inspect}"
    end
  end

  desc "Promote pending ESPN team mappings to approved (LEAGUE=eng.2 or all)"
  task :approve_team_mappings => :environment do
    scope = ExternalIdentifier.where(provider: "espn", review_state: "pending")
    count = scope.update_all(review_state: "approved", updated_at: Time.current)
    puts "approved #{count} pending ESPN team mapping(s)"
  end

  desc "List ESPN team mappings still pending review"
  task :pending_team_mappings => :environment do
    rows = ExternalIdentifier.where(provider: "espn", review_state: "pending")
                             .includes(:team).order(:id)
    puts "pending: #{rows.size}"
    rows.each { |r| puts format("  %-6s -> %s", r.external_id, r.team&.name || "(no team)") }
  end
end
