require "rails_helper"

# Runs a validated manifest, one file at a time.
#
# A multi-file history import is NOT globally atomic, and pretending otherwise
# would be a lie an operator could act on. Each file is imported through the
# single-file importer, which is transactional on its own; if file 3 of 5 fails,
# files 1-2 stay imported. What the runner must guarantee instead:
#
#   - every entry carries its own season, so files cannot bleed into one another
#   - one failure does not abort the remaining entries silently: the outcome says
#     exactly which succeeded and which did not
#   - re-running the whole manifest is safe, because each file import is idempotent
#   - entries are processed in manifest order, never concurrently, because
#     concurrent imports compete for the same mapping rows
RSpec.describe Import::HistoryRunner do
  let(:fixture_path) do
    Rails.root.join("..", "data", "fixtures", "football_data_premier_league_sample.csv").to_s
  end

  let(:mixed_path) do
    Rails.root.join("..", "data", "fixtures",
                    "football_data_premier_league_sample_mixed_statuses.csv").to_s
  end

  around do |example|
    Dir.mktmpdir("history_runner_spec") do |dir|
      original = ENV.fetch("IMPORT_ALLOWED_ROOTS", nil)
      ENV["IMPORT_ALLOWED_ROOTS"] = [original, dir].compact.join(File::PATH_SEPARATOR)
      @dir = dir
      example.run
    ensure
      original.nil? ? ENV.delete("IMPORT_ALLOWED_ROOTS") : ENV["IMPORT_ALLOWED_ROOTS"] = original
    end
  end

  def manifest(*entries)
    Import::Manifest.new(entries: entries)
  end

  def entry(path, season, competition: "E0")
    { path: path, season: season, competition: competition }
  end

  def broken_file(name = "broken.csv")
    path = File.join(@dir, name)
    File.write(path, "Div,Date,Time,HomeTeam,AwayTeam,FTHG,FTAG,FTR\n" \
                     "E0,17/08/2024,15:00,,Chelsea,1,0,H\n")
    path
  end

  describe "a fully successful run" do
    let(:runner) do
      described_class.new(
        manifest(entry(fixture_path, "2024/25"), entry(mixed_path, "2025/26"))
      )
    end

    it "imports every entry" do
      outcome = runner.call

      expect(outcome).to be_success
      expect(outcome.results.length).to eq(2)
      expect(outcome.results).to all(satisfy(&:success?))
    end

    it "imports each file under its own season" do
      runner.call

      expect(Season.pluck(:name)).to contain_exactly("2024/25", "2025/26")
      expect(Match.joins(:season).group("seasons.name").count).to eq("2024/25" => 7, "2025/26" => 7)
    end

    it "reports the totals across all files" do
      outcome = runner.call

      expect(outcome.total_created).to eq(14)
      expect(outcome.total_skipped).to eq(0)
    end

    it "processes entries in manifest order" do
      order = []
      allow_any_instance_of(Import::MatchImporter).to receive(:call) do |importer|
        order << importer.instance_variable_get(:@season_label)
        Import::Result.success(input: 0)
      end

      runner.call

      expect(order).to eq(%w[2024/25 2025/26])
    end
  end

  describe "partial failure" do
    let(:runner) do
      described_class.new(
        manifest(
          entry(fixture_path, "2024/25"),
          entry(broken_file, "2025/26"),
          entry(mixed_path, "2026/27")
        )
      )
    end

    it "reports the run as failed" do
      expect(runner.call).to be_failure
    end

    it "continues after a failing entry so partial progress is visible" do
      outcome = runner.call

      expect(outcome.results.length).to eq(3)
      expect(outcome.results.map(&:success?)).to eq([true, false, true])
    end

    it "keeps the successful imports" do
      runner.call

      expect(Season.pluck(:name)).to contain_exactly("2024/25", "2026/27")
      expect(Match.count).to eq(14)
    end

    it "names the failed entry and its error" do
      outcome = runner.call
      failure = outcome.failures.first

      expect(File.basename(failure.entry.path)).to eq("broken.csv")
      expect(failure.error).to match(/home team/i)
    end

    it "does not claim the whole run was atomic" do
      outcome = runner.call

      expect(outcome.partial?).to be(true)
      expect(outcome.summary).to match(/2 of 3|2 succeeded/i)
    end
  end

  describe "re-execution and retry safety" do
    let(:runner) do
      described_class.new(manifest(entry(fixture_path, "2024/25"), entry(mixed_path, "2025/26")))
    end

    it "creates nothing new on a second run" do
      runner.call
      before = { matches: Match.count, identifiers: ExternalIdentifier.count }

      outcome = runner.call

      expect(outcome).to be_success
      expect(outcome.total_created).to eq(0)
      expect(outcome.total_skipped).to eq(14)
      expect(Match.count).to eq(before[:matches])
      expect(ExternalIdentifier.count).to eq(before[:identifiers])
    end

    it "only re-processes what failed on a retry" do
      failing = described_class.new(
        manifest(entry(fixture_path, "2024/25"), entry(broken_file, "2025/26"))
      )
      failing.call

      # The operator fixes the file; a retry must not duplicate the first entry.
      fixed = described_class.new(
        manifest(entry(fixture_path, "2024/25"), entry(mixed_path, "2025/26"))
      )
      outcome = fixed.call

      expect(outcome).to be_success
      expect(Match.count).to eq(14)
    end
  end

  describe "guards" do
    it "refuses to run an invalid manifest" do
      outcome = described_class.new(manifest).call

      expect(outcome).to be_failure
      expect(outcome.summary).to match(/manifest/i)
      expect(Match.count).to eq(0)
    end

    it "does not run entries concurrently" do
      # Sequential execution is a deliberate choice: concurrent imports contend
      # for the same mapping rows. This guards against someone "speeding it up".
      expect(described_class::CONCURRENCY).to eq(1)
    end
  end
end
