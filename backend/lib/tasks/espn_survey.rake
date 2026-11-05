# Read-only ESPN coverage survey across competitions.
#
# ONE workflow for every league: the competition code is the only input that
# changes. Nothing here is league-specific, and nothing is written — the survey
# uses EspnTeamIdentity (pure) and ReconciliationPreview (no persistence).
#
# Usage:
#   bundle exec rake espn:survey                       # all unmapped competitions
#   bundle exec rake espn:survey CODES=SP1             # one pilot
#   bundle exec rake espn:survey SEASON=2026/27 FROM=20261101 TO=20261130
namespace :espn do
  # The nine competitions with no approved ESPN club mappings, per handout §13.
  UNMAPPED_CODES = %w[SC0 SP1 D1 I1 F1 N1 B1 P1 T1].freeze

  desc "Read-only ESPN identity + fixture preview (no writes). CODES=SP1,D1 SEASON=2026/27"
  task survey: :environment do
    codes = (ENV["CODES"] || UNMAPPED_CODES.join(",")).split(",").map(&:strip)
    season_name = ENV.fetch("SEASON", Sync::SeasonWindow.current_label)
    from_date = Date.parse(ENV.fetch("FROM", (Date.current - 30).iso8601))
    to_date = Date.parse(ENV.fetch("TO", (Date.current + 120).iso8601))

    puts "survey: #{codes.join(', ')} | season #{season_name} | #{from_date}..#{to_date}"
    puts "mode: READ-ONLY (no mappings persisted, no fixtures written)"
    puts

    survey = Sync::EspnCoverageSurvey.new
    results = survey.call(codes: codes, season_name: season_name,
                          from_date: from_date, to_date: to_date)

    header = format("%-4s %-9s %6s %7s %8s %5s %5s %6s %8s %8s %6s",
                    "code", "slug", "clubs", "espn", "verified", "exi", "amb", "unmap", "resolved", "new", "status")
    puts header
    puts "-" * header.length

    results.each do |code, row|
      if row[:status] != :ok
        puts format("%-4s %-9s %60s %s", code, "-", row[:status], row[:error].to_s[0, 60])
        next
      end

      counts = row[:counts]
      puts format("%-4s %-9s %6d %7d %8d %5d %5d %6d %8d %8d %6s",
                  code, row[:slug], row[:canonical_clubs], row[:provider_teams],
                  row[:verified], row[:existing], row[:ambiguous], row[:unmapped],
                  counts[:resolved], counts[:would_create], row[:status])
    end

    puts
    results.each do |code, row|
      next unless row[:status] == :ok

      if row[:unmatched_names].any?
        puts "#{code} unmapped ESPN names: #{row[:unmatched_names].join(', ')}"
      end
      if row[:ambiguous_names].any?
        puts "#{code} ambiguous ESPN names: #{row[:ambiguous_names].join(', ')}"
      end
    end
  end
end
