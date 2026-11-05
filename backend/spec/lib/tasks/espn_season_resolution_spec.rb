require "rails_helper"
require "rake"

# Both ESPN entry points must resolve the season through Sync::EspnLeagueSeason.
#
# WHY THIS IS A SEPARATE SPEC
# ---------------------------
# The defect survived in `espn:ingest` after it was fixed in `espn:discover`,
# because each task had its own `Season.find_by(name:)`. A test of the resolver
# alone cannot catch that: both tasks would keep passing while one of them still
# wrote into another competition's season. These specs assert the *call sites*.
RSpec.describe "ESPN season resolution at the entry points" do
  # Rake tasks load once for the whole file, matching
  # spec/tasks/import_download_task_spec.rb. Without this, Rake::Task is
  # undefined and neither entry point can be exercised at all.
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  # Loading the tasks registers cron entries against Redis as an import-time side
  # effect, and sidekiq-cron removes them again when the process exits — verified:
  # `Sidekiq::Cron::Job.all.size` is 0 after this file runs. Nothing here changes
  # the deployed schedule, and no worker is running to execute anything.
  let!(:e0) { Competition.find_or_create_by!(code: "E0") { |c| c.name = "Premier League" } }
  let!(:e1) { Competition.find_or_create_by!(code: "E1") { |c| c.name = "Championship" } }
  let!(:sc0) { Competition.find_or_create_by!(code: "SC0") { |c| c.name = "Scottish Premiership" } }
  let!(:e0_season) do
    Season.find_or_create_by!(competition: e0, name: "2026/27") do |s|
      s.start_date = Date.new(2026, 7, 1)
      s.end_date = Date.new(2027, 6, 30)
    end
  end
  let!(:e1_season) do
    Season.find_or_create_by!(competition: e1, name: "2026/27") do |s|
      s.start_date = Date.new(2026, 7, 1)
      s.end_date = Date.new(2027, 6, 30)
    end
  end

  describe "espn:ingest" do
    it "hands the Championship season to the synchronizer for eng.2" do
      received = nil
      allow_any_instance_of(Sync::EspnSynchronizer).to receive(:call) do |_inst, kwargs|
        received = kwargs
        Sync::SyncRun.create!(kind: "fixtures", trigger: "manual", status: "succeeded",
                              started_at: Time.current, finished_at: Time.current, details: {})
      end

      Rake::Task["espn:ingest"].reenable
      Rake::Task["espn:ingest"].invoke("eng.2", "2026/27", "20261128")

      expect(received[:internal_season]).to eq(e1_season)
      expect(received[:internal_season]).not_to eq(e0_season)
    end

    it "refuses an unmapped league instead of falling back to another competition" do
      Rake::Task["espn:ingest"].reenable
      expect { Rake::Task["espn:ingest"].invoke("eng.99", "2026/27", "20261128") }.to raise_error(SystemExit)
    end
  end

  describe "espn:discover" do
    it "hands the Championship season to the discovery synchronizer for eng.2" do
      received = nil
      allow_any_instance_of(Sync::EspnDiscoverySynchronizer).to receive(:call) do |_inst, kwargs|
        received = kwargs
        Sync::SyncRun.create!(kind: "fixtures", trigger: "manual", status: "succeeded",
                              started_at: Time.current, finished_at: Time.current, details: {})
      end

      ENV["FROM"] = "20261128"
      ENV["TO"] = "20261128"
      Rake::Task["espn:discover"].reenable
      Rake::Task["espn:discover"].invoke("eng.2", "2026/27")

      expect(received[:internal_season]).to eq(e1_season)
    ensure
      ENV.delete("FROM")
      ENV.delete("TO")
    end

    it "refuses a league whose season this competition does not have" do
      # SC0 EXISTS here but keeps no 2027/28 season, while E0 does. Discovery must
      # stop rather than borrow E0's season — the Scottish case, where guessing a
      # season would have filed matches into the wrong competition.
      Season.find_or_create_by!(competition: e0, name: "2027/28") do |s|
        s.start_date = Date.new(2027, 7, 1)
        s.end_date = Date.new(2028, 6, 30)
      end
      ENV["FROM"] = "20270705"
      ENV["TO"] = "20270705"
      Rake::Task["espn:discover"].reenable

      expect { Rake::Task["espn:discover"].invoke("sco.1", "2027/28") }
        .to raise_error(SystemExit)
    ensure
      ENV.delete("FROM")
      ENV.delete("TO")
    end
  end

  it "has no ESPN path that resolves a season by name alone" do
    # A static guard: the bug was a lookup that ignored the competition. Any
    # reappearance of `Season.find_by(name:` in ESPN code fails here rather than
    # in production.
    #
    # Comments are stripped first, so prose explaining the old defect cannot trip
    # the guard — a guard that fires on documentation is one people delete.
    files = Dir[Rails.root.join("app/services/sync/espn*.rb").to_s] +
            Dir[Rails.root.join("app/services/espn*.rb").to_s] +
            Dir[Rails.root.join("app/services/import/espn*.rb").to_s] +
            Dir[Rails.root.join("app/jobs/*espn*.rb").to_s] +
            Dir[Rails.root.join("lib/tasks/espn*.rake").to_s]

    expect(files).not_to be_empty

    offenders = files.select do |path|
      code = File.read(path).lines.reject { |line| line.strip.start_with?("#") }.join
      code.match?(/Season\.find_by\(\s*name:/)
    end

    expect(offenders).to be_empty
  end
end
