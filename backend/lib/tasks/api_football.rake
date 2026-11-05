# Operational entry points for API-Football ingestion.
#
# These exist so operators never need to open a console, and so each step is a
# single command with visible counts. Every task is idempotent: running one
# twice must not duplicate anything.
namespace :api_football do
  desc "Report connectivity and remaining quota (never prints the key)"
  task status: :environment do
    client = Import::ApiFootballClient.new
    result = client.get("/status")
    puts "provider reachable: yes"
    puts "quota remaining:  #{result.quota_remaining}/#{result.quota_limit}"
  end

  desc "Map internal teams to API-Football team ids for a league/season (DRY_RUN=1 to preview)"
  task :map_teams, %i[league season competition_code] => :environment do |_t, args|
    league = args[:league] || "39"
    season = args[:season] || "2024"
    code = args[:competition_code]
    dry_run = ENV["DRY_RUN"] == "1"

    client = Import::ApiFootballClient.new
    teams = client.get("/teams", query: { league: league, season: season }).records

    mapped = 0
    ambiguous = []

    teams.each do |entry|
      provider_id = entry.dig("team", "id")&.to_s
      name = entry.dig("team", "name")
      next if provider_id.nil? || name.nil?

      # Match on the NORMALISED name the importer already maintains. There is no
      # fuzzy fallback on purpose: auto-merging "Man Utd" into "Manchester
      # United" would create two canonical teams for one club.
      normalized = Team.normalize_name(name)
      candidates = Team.where(normalized_name: normalized).to_a

      if candidates.size == 1
        unless dry_run
          ExternalIdentifier.find_or_create_by!(provider: "api_football", external_id: provider_id) do |identifier|
            identifier.team = candidates.first
          end
        end
        mapped += 1
      elsif candidates.size > 1
        ambiguous << [provider_id, name, candidates.map(&:id)]
      end
    end

    puts "provider teams: #{teams.size}"
    puts "mapped:         #{mapped}#{" (dry run)" if dry_run}"
    puts "ambiguous:      #{ambiguous.size}"
    ambiguous.first(10).each { |a| puts "  AMBIGUOUS #{a.inspect}" }
    puts "Competition #{code} unscoped: mapping is per club, reused across seasons." if code.nil?
  end

  desc "Ingest a league season fixtures (LEAGUE=39 SEASON=2024 CODE=E0 SEASON_LABEL=2024/25)"
  task :ingest, %i[league season season_label code] => :environment do |_t, args|
    league = args[:league] || "39"
    season = args[:season] || "2024"
    label = args[:season_label]
    code = args[:code] || ENV["CODE"]

    # The internal season is resolved WITHIN a competition, never by name alone.
    # Season names are not unique across competitions (everyone has a "2026/27"),
    # so `Season.find_by(name: label)` returned whichever row came first — the
    # same defect that put 139 Championship fixtures into the Premier League via
    # ESPN. The catalogue code is required; API-Football's league id (39) is a
    # PROVIDER id and is deliberately kept separate from it.
    abort "Provide the internal competition code (e.g. CODE=E0); " \
          "the season cannot be resolved by name alone." if code.blank?

    competition = Competition.find_by(code: code.to_s)
    abort "No internal Competition with code #{code.inspect}" if competition.nil?
    abort "No season label given" if label.blank?

    internal_season = Season.find_by(competition_id: competition.id, name: label.to_s)
    if internal_season.nil?
      abort "Competition #{code} (#{competition.name}) has no season named #{label.inspect}"
    end

    run = Sync::ApiFootballFixtureSynchronizer.new.call(
      league: league, season: season, internal_season: internal_season,
    )
    puts "competition: #{competition.code} #{competition.name} (season_id=#{internal_season.id})"
    puts "status=#{run.status} fetched=#{run.fetched} created=#{run.created} " \
         "updated=#{run.updated} skipped=#{run.skipped} rejected=#{run.rejected}"
    puts "error: #{run.last_error}" if run.last_error
    puts "details: #{run.details.inspect}"
  end

  desc "Discover and update currently live fixtures for mapped competitions"
  task live: :environment do
    run = Sync::ApiFootballLiveSynchronizer.new.call
    puts "status=#{run.status} fetched=#{run.fetched} updated=#{run.updated} " \
         "skipped=#{run.skipped} rejected=#{run.rejected}"
    puts "details: #{run.details.inspect}"
  end
end
