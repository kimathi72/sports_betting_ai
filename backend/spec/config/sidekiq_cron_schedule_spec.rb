require "rails_helper"

# The recurring schedule is configuration, but configuration that silently does
# nothing is the failure mode this project has already been hurt by. These specs
# assert the schedule is well-formed enough that sidekiq-cron can actually run it:
#
#   - a valid six-field cron expression (sidekiq-cron evaluates it with fugit),
#   - an explicit timezone, because "03:00" without one is a different instant on
#     every deployment and would run twice or not at all across a DST change,
#   - a job class that exists and is a real job,
#   - one entry per kind, so nothing is scheduled twice.
RSpec.describe "Sidekiq-Cron schedule" do
  let(:entries) { Sidekiq::Cron::Job.all }
  let(:by_name) { entries.index_by(&:name) }

  it "registers exactly one fixtures and one results schedule" do
    expect(by_name.keys).to include("sync_fixtures", "sync_results")
    expect(entries.map(&:name).tally.values).to all(eq(1))
  end

  it "runs a real job class for each entry" do
    expect(by_name["sync_fixtures"].klass).to eq("SyncFixturesJob")
    expect(by_name["sync_results"].klass).to eq("SyncResultsJob")
  end

  it "pins every entry to an explicit timezone" do
    entries.each do |entry|
      expect(entry.cron).not_to be_nil
      # sidekiq-cron stores the zone on the parsed schedule; a nil zone means the
      # expression is interpreted in whatever TZ the container happens to have.
      expect(entry.cron).to match(/\sUTC\z/).or match(/\s[A-Za-z]+\/[A-Za-z_]+\z/)
    end
  end

  it "uses valid cron expressions that sidekiq-cron can parse" do
    entries.each do |entry|
      expect { Fugit.parse_cron(entry.cron) }.not_to raise_error
      expect(Fugit.parse_cron(entry.cron)).not_to be_nil
    end
  end

  it "publishes a next occurrence for every entry" do
    # fugit returns an EtOrbi::EoTime, not a Time; compare via #to_t.
    entries.each do |entry|
      expect(Fugit.parse_cron(entry.cron).next_time.to_t).to be_a(Time)
    end
  end

  it "runs the daily synchronizations once a day and live polling on its own cadence" do
    # The daily entries must not repeat within a day: a fixture import that runs
    # more often than daily would exhaust the provider quota.
    #
    # TWO entries are deliberate exceptions, and both are bounded separately
    # below: live polling (bounded to match hours) and the result-check dispatcher
    # (a DATABASE QUERY that makes no provider request at all).
    sub_daily = %w[api_football_live match_result_dispatch]
    daily = entries.reject { |entry| sub_daily.include?(entry.name) }
    expect(daily).not_to be_empty

    daily.each do |entry|
      first = Fugit.parse_cron(entry.cron).next_time
      second = Fugit.parse_cron(entry.cron).next_time(first + 1)
      expect(second - first).to be_within(60).of(24.hours)
    end
  end

  it "runs the result-check dispatcher every five minutes, round the clock" do
    # The dispatcher only queries PostgreSQL and enqueues jobs; it never calls
    # ESPN, so a five-minute cadence costs no provider quota. It must not be
    # hour-restricted: a match can finish at any hour.
    # `by_name` holds sidekiq-cron objects; the class name lives in the
    # definition the schedule builds.
    definition = SidekiqCronSchedule.definitions.find { |d| d["name"] == "match_result_dispatch" }
    expect(definition).to be_present
    expect(definition["cron"]).to match(%r{^\*/5 \* \* \* \*})
    expect(definition["class"]).to eq("MatchResultDispatchJob")
  end

  it "bounds live polling to a match window rather than round the clock" do
    live = by_name["api_football_live"]
    expect(live).to be_present
    # A 100-request/day plan cannot afford an always-on poller; the window is
    # what makes the 5-minute interval affordable.
    expect(live.cron).to match(/^\*\/5 12-22 /)
  end
end
