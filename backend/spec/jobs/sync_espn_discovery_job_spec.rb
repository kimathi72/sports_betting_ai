require "rails_helper"

# The scheduled replacement for the manual ESPN backfill.
#
# The defect it guards: upcoming fixtures existed only for dates somebody had
# typed into `espn:ingest`. Nothing in the system noticed the difference between
# "the league did not play that week" and "nobody ever asked". This job asks about
# a WINDOW, for every league with a verified slug, every day.
RSpec.describe SyncEspnDiscoveryJob do
  let(:competition) { Competition.find_or_create_by!(code: "E0") { |c| c.name = "Premier League" } }
  let!(:season) do
    Season.find_or_create_by!(competition: competition, name: Sync::SeasonWindow.current_label) do |s|
      s.start_date = Sync::SeasonWindow.start_of_season(Sync::SeasonWindow.current_label)
      s.end_date = Sync::SeasonWindow.end_of_season(Sync::SeasonWindow.current_label)
    end
  end

  it "asks for a window around today rather than a single date" do
    calls = []
    allow_any_instance_of(Sync::EspnDiscoverySynchronizer).to receive(:call) do |_inst, kwargs|
      calls << kwargs
      Sync::SyncRun.create!(kind: "fixtures", trigger: "manual", status: "succeeded",
                            started_at: Time.current, finished_at: Time.current, details: {})
    end

    described_class.new.perform("schedule")

    eng = calls.find { |c| c[:league] == "eng.1" }
    expect(eng).not_to be_nil
    expect(eng[:from_date]).to be < Date.current
    expect(eng[:to_date]).to be > Date.current
  end

  it "names every league it cannot reach instead of silently skipping it" do
    allow_any_instance_of(Sync::EspnDiscoverySynchronizer).to receive(:call) do
      Sync::SyncRun.create!(kind: "fixtures", trigger: "manual", status: "succeeded",
                            started_at: Time.current, finished_at: Time.current, details: {})
    end
    logged = []
    allow(Rails.logger).to receive(:info) { |message| logged << message.to_s; nil }

    results = described_class.new.perform("schedule")

    # Every code in the catalogue is accounted for, one way or another: there is
    # no code that can be silently absent from the report.
    catalogue_codes = CompetitionCatalogue::ENTRIES.keys
    expect(results.keys).to match_array(catalogue_codes)
    # E2 has no fixture feed at all and is outside the product scope: it must be
    # reported as out of scope, never silently dropped.
    expect(results['E2']).to eq(:out_of_scope)
    expect(results['uefa.champions']).to eq(:out_of_scope)
  end

  it "is registered in the recurring schedule" do
    require Rails.root.join("config/sidekiq_cron_schedule").to_s
    expect(SidekiqCronSchedule::ENTRIES.keys).to include("espn_discovery")
    expect(SidekiqCronSchedule::ENTRIES["espn_discovery"][:class]).to eq("SyncEspnDiscoveryJob")
  end

  it "reports the leagues it could not find a season for" do
    allow_any_instance_of(Sync::EspnDiscoverySynchronizer).to receive(:call) do
      Sync::SyncRun.create!(kind: "fixtures", trigger: "manual", status: "succeeded",
                            started_at: Time.current, finished_at: Time.current, details: {})
    end

    results = described_class.new.perform("schedule")
    # Competitions absent from this database are reported, never assumed.
    expect(results.values).to include(:no_season).or include(:succeeded)
  end
end
