# Operation entry points for the ESPN provider.
#
# ESPN fills the gap API-Football's free tier leaves: the CURRENT season. It
# needs no credentials, so it is the default provider for upcoming fixtures and
# live status.
namespace :espn do
  desc "Map ESPN team ids onto canonical teams (DRY_RUN=1 to preview)"
  task :map_teams, [:league] => :environment do |_t, args|
    league = args[:league] || "eng.1"
    dry_run = ENV["DRY_RUN"] == "1"

    client = Import::EspnClient.new
    uri = URI("#{Import::EspnClient::BASE_URL}/#{league}/teams")
    http = Net::HTTP.new(uri.host, uri.port).tap { |h| h.use_ssl = true }
    body = JSON.parse(Zlib::GzipReader.new(StringIO.new(
      http.start do |c|
        req = Net::HTTP::Get.new(uri)
        req["Accept-Encoding"] = "gzip"
        c.request(req)
      end.body
    )).read)

    teams = body.dig("sports", 0, "leagues", 0, "teams") || []

    mapped = 0
    unmapped = []
    ambiguous = []

    teams.each do |entry|
      team = entry["team"]
      provider_id = team["id"].to_s
      display = team["displayName"].to_s
      short = team["shortDisplayName"].to_s

      # Try the full name, then ESPN's short name. Both go through the same
      # normaliser the importer uses, so "Nott'm Forest" and "Nottingham Forest"
      # reduce to the same key.
      candidates = [display, short].uniq.filter_map do |name|
        next if name.empty?

        Team.where(normalized_name: Team.normalize(name)).to_a
      end.flatten.uniq

      if candidates.size == 1
        unless dry_run
          ExternalIdentifier.find_or_create_by!(provider: "espn", external_id: provider_id) do |identifier|
            identifier.team = candidates.first
          end
        end
        mapped += 1
      elsif candidates.size > 1
        ambiguous << [provider_id, display, candidates.map(&:id)]
      else
        unmapped << [provider_id, display, short]
      end
    end

    puts "ESPN teams: #{teams.size}"
    puts "mapped:     #{mapped}#{" (dry run)" if dry_run}"
    puts "ambiguous:  #{ambiguous.size}"
    ambiguous.each { |a| puts "  AMBIGUOUS #{a.inspect}" }
    puts "unmapped:   #{unmapped.size}"
    unmapped.each { |u| puts "  UNMAPPED #{u.inspect}" }
  end

  desc "Ingest an ESPN scoreboard for a date into an internal season"
  task :ingest, [:league, :season_label, :date] => :environment do |_t, args|
    league = args[:league] || "eng.1"
    label = args[:season_label]
    date = args[:date]

    # Same resolver as discovery, and for the same reason: `Season.find_by(name:)`
    # returned whichever competition owned that season name first — the Premier
    # League — so ingesting another league wrote into the wrong season. This task
    # had the identical defect after discovery was fixed; both now go through one
    # code path.
    begin
      season = Sync::EspnLeagueSeason.for_league(league, label)
    rescue Sync::EspnLeagueSeason::UnknownLeague,
           Sync::EspnLeagueSeason::UnknownCompetition,
           Sync::EspnLeagueSeason::UnknownSeason,
           Sync::EspnLeagueSeason::AmbiguousSeason => e
      abort "Cannot ingest #{league.inspect} into #{label.inspect}: #{e.message}"
    end

    run = Sync::EspnSynchronizer.new.call(
      league: league, internal_season: season, date: date,
    )
    puts "season: #{season.competition.code} #{season.name} (season_id=#{season.id})"
    puts "status=#{run.status} fetched=#{run.fetched} created=#{run.created} " \
         "updated=#{run.updated} skipped=#{run.skipped} rejected=#{run.rejected}"
    puts "error: #{run.last_error}" if run.last_error
    puts "details: #{run.details.inspect}"
  end

  desc "Discover every fixture in a date window (FROM=YYYYMMDD TO=YYYYMMDD, LEAGUE=eng.1, SEASON=2026/27)"
  task :discover, %i[league season_label] => :environment do |_t, args|
    league = args[:league] || ENV.fetch("LEAGUE", "eng.1")
    label = args[:season_label] || ENV.fetch("SEASON", Sync::SeasonWindow.current_label)

    # ONE resolver for both entry points. `for_league` translates the slug through
    # EspnLeagueCoverage and resolves the season inside that competition only, so
    # a league can never be handed another competition's season. It raises rather
    # than returning nil, so an unresolvable league stops here with a reason.
    begin
      season = Sync::EspnLeagueSeason.for_league(league, label)
    rescue Sync::EspnLeagueSeason::UnknownLeague,
           Sync::EspnLeagueSeason::UnknownCompetition,
           Sync::EspnLeagueSeason::UnknownSeason,
           Sync::EspnLeagueSeason::AmbiguousSeason => e
      abort "Cannot discover #{league.inspect} in #{label.inspect}: #{e.message}"
    end

    puts "season: #{season.competition.code} #{season.name} (season_id=#{season.id})"

    from_date = Date.parse(ENV.fetch("FROM", Sync::SeasonWindow.start_of_season(label).iso8601))
    to_date = Date.parse(ENV.fetch("TO", Sync::SeasonWindow.end_of_season(label).iso8601))

    run = Sync::EspnDiscoverySynchronizer.new.call(
      league: league, internal_season: season,
      from_date: from_date, to_date: to_date, trigger: ENV.fetch("TRIGGER", "manual")
    )
    puts "status=#{run.status} fetched=#{run.fetched} created=#{run.created} " \
         "updated=#{run.updated} skipped=#{run.skipped} rejected=#{run.rejected}"
    puts "window: #{run.details["from"]}..#{run.details["to"]} " \
         "(days searched: #{run.details["days_searched"]}, with events: #{run.details["days_with_events"].to_h.size})"
    puts "deferred: #{run.details["deferred"]}" if run.details["deferred"]
    puts "error: #{run.last_error}" if run.last_error
  end
end
