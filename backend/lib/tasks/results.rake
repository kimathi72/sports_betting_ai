# Daily RESULT collection from ESPN — preview by default.
#
#   rake 'results:sync[2026-11-03,2026-11-04]'              # PREVIEW, writes nothing
#   APPLY=1 rake 'results:sync[2026-11-03,2026-11-04]'      # applies
#   LEAGUES=eng.1,eng.2 rake 'results:sync[...]'            # limit the leagues
#
# WHAT IT DOES PER LEAGUE
#   - resolves the internal season through Sync::EspnLeagueSeason (scoped, refuses
#     an ambiguous or unknown league),
#   - asks ESPN once per calendar day in the window,
#   - hands every event to Sync::EspnResultSynchronizer.
#
# It NEVER creates a fixture, never overwrites a stored completed result, and never
# writes a score for a postponed/abandoned/cancelled match. A conflict is listed for
# review and left untouched.
#
# NOT SCHEDULED. This is deliberately a manual task: enabling it on a timer is a
# policy decision (cadence, who reads the conflict list), and this project starts
# background writes only on explicit instruction.
namespace :results do
  desc "Collect final results from ESPN for a date window (preview unless APPLY=1)"
  task :sync, %i[from to] => :environment do |_t, args|
    apply = ENV["APPLY"].to_s.match?(/\A(1|true|yes)\z/i)
    from = args[:from] ? Date.parse(args[:from]) : Date.current - 1
    to = args[:to] ? Date.parse(args[:to]) : Date.current
    leagues = ENV["LEAGUES"].to_s.split(",").map(&:strip).reject(&:empty?)

    catalogue = if leagues.empty?
                  EspnLeagueCoverage::VERIFIED.map { |code, slug| [code, slug] }
                else
                  leagues.map do |slug|
                    code = EspnLeagueCoverage.code_for_slug(slug)
                    raise SystemExit, "unknown ESPN league #{slug.inspect}" if code.nil?

                    [code, slug]
                  end
                end

    puts "results:sync — #{apply ? 'APPLY' : 'PREVIEW (nothing written; APPLY=1 to write)'}"
    puts "window: #{from} .. #{to}   leagues: #{catalogue.map(&:first).join(', ')}   days: #{(to - from).to_i + 1}"
    puts

    synchronizer = Sync::EspnResultSynchronizer.new
    totals = Hash.new(0)
    conflicts = []

    catalogue.each do |code, slug|
      season = begin
        Sync::EspnLeagueSeason.for_league(slug, Sync::SeasonWindow.current_label(at: Time.current))
      rescue Sync::EspnLeagueSeason::UnknownSeason, Sync::EspnLeagueSeason::AmbiguousSeason => e
        puts format("%-4s %-8s skipped: %s", code, slug, e.message[0, 80])
        next
      end

      line = { code: code, fetched: 0, completed: 0, unchanged: 0, conflicts: 0,
               rescheduled: 0, postponed: 0, rejected: 0, ignored: 0 }

      (from..to).each do |day|
        report = if apply
                   synchronizer.call(league: slug, season: season, date: day, trigger: "manual")
                 else
                   synchronizer.preview(league: slug, season: season, date: day, trigger: "manual")
                 end
        next if report.nil? # provider failure; the ledger row carries the reason

        line[:fetched] += report.fetched
        line[:completed] += report.completed.size
        line[:unchanged] += report.unchanged.size
        line[:conflicts] += report.conflicts.size
        line[:rescheduled] += report.rescheduled.size
        line[:postponed] += report.postponed.size
        line[:rejected] += report.rejected.size
        line[:ignored] += report.ignored.size

        report.conflicts.each do |conflict|
          conflicts << { league: code, day: day.iso8601 }.merge(conflict.to_h)
        end
        report.completed.first(5).each do |entry|
          puts format("  %-4s %s COMPLETE match=%s score=%s", code, day, entry.match_id, entry.detail[:score].inspect)
        end
        report.planned.select { |p| p.action == :would_complete }.first(5).each do |entry|
          puts format("  %-4s %s WOULD COMPLETE match=%s score=%s", code, day, entry.match_id, entry.detail[:score].inspect)
        end
      end

      line.each { |key, value| totals[key] += value if key != :code }
      puts format("%-4s %-8s fetched=%-5d completed=%-4d unchanged=%-5d conflicts=%-3d " \
                  "rescheduled=%-3d postponed=%-3d rejected=%-3d ignored=%-4d",
                  code, slug, line[:fetched], line[:completed], line[:unchanged],
                  line[:conflicts], line[:rescheduled], line[:postponed],
                  line[:rejected], line[:ignored])
    end

    puts
    puts "TOTAL      fetched=#{totals[:fetched]} completed=#{totals[:completed]} " \
         "unchanged=#{totals[:unchanged]} conflicts=#{totals[:conflicts]} " \
         "rescheduled=#{totals[:rescheduled]} postponed=#{totals[:postponed]} " \
         "rejected=#{totals[:rejected]} ignored=#{totals[:ignored]}"

    if conflicts.any?
      puts
      puts "CONFLICTS — stored result kept, manual review required:"
      conflicts.each { |c| puts "  #{c.to_json}" }
    end

    puts
    puts apply ? "Applied. Every change is recorded in sync_runs (kind=results)." : "Preview only. Nothing was written."
  end
end
