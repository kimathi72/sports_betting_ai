require "rails_helper"

# Seasons before 2019/20 publish no kickoff `Time` column at all.
#
# The downloader already accepts those files (and records
# `has_time_column: false`), so the import pipeline must accept them too, or
# three seasons of real history are permanently unreachable. The crucial rule is
# that a missing time must NEVER be replaced with an invented one: a fabricated
# midnight kickoff would corrupt feature engineering (it would make every such
# fixture look like a late-night match) and make the import irreproducible.
#
# The importer therefore keeps the fixture with a date-accurate instant derived
# from the only thing the source actually published: the date.
RSpec.describe Import::FootballDataCoUkAdapter, "files without a Time column" do
  let(:timeless_row) do
    {
      "Div" => "E0", "Date" => "13/08/2016",
      "HomeTeam" => "Hull", "AwayTeam" => "Leicester",
      "FTHG" => "2", "FTAG" => "1", "FTR" => "H",
    }
  end

  it "declares Time as optional rather than required" do
    expect(Import::FootballDataCoUkAdapter::REQUIRED_COLUMNS).not_to include("Time")
    expect(Import::FootballDataCoUkAdapter::OPTIONAL_COLUMNS).to include("Time")
  end

  it "parses a row with no Time key at all" do
    result = described_class.parse(timeless_row)

    expect(result).to be_success
    expect(result.row.status).to eq("completed")
    expect(result.row.home_score).to eq(2)
    expect(result.row.away_score).to eq(1)
  end

  it "marks the row as having no kickoff time rather than inventing one" do
    result = described_class.parse(timeless_row)

    expect(result.row.time_known).to be(false)
  end

  it "derives the instant from the published date only" do
    result = described_class.parse(timeless_row)

    expect(result.row.kickoff_at.utc.strftime("%Y-%m-%d")).to eq("2016-08-13")
  end

  it "still records a known time when the column is present" do
    row = timeless_row.merge("Time" => "15:00")

    result = described_class.parse(row)

    expect(result.row.time_known).to be(true)
    expect(result.row.kickoff_at).to eq(Time.utc(2016, 8, 13, 15, 0))
  end

  it "does not make kickoffs collide when every fixture lacks a time" do
    # If every timeless fixture defaulted to the same hour, distinct fixtures
    # could still be told apart by the provider key (date + teams), but a
    # presentation bug would be hard to spot. The key must stay unique per
    # fixture.
    a = described_class.parse(timeless_row).row
    b = described_class.parse(timeless_row.merge("AwayTeam" => "Arsenal")).row

    expect(a.provider_key).not_to eq(b.provider_key)
  end
end

RSpec.describe Import::MatchImporter, "files without a Time column" do
  around do |example|
    Dir.mktmpdir("timeless_spec") do |dir|
      original = ENV.fetch("IMPORT_ALLOWED_ROOTS", nil)
      ENV["IMPORT_ALLOWED_ROOTS"] = [original, dir].compact.join(File::PATH_SEPARATOR)
      @dir = dir
      example.run
    ensure
      original.nil? ? ENV.delete("IMPORT_ALLOWED_ROOTS") : ENV["IMPORT_ALLOWED_ROOTS"] = original
    end
  end

  def timeless_csv
    path = File.join(@dir, "1617_E0.csv")
    File.write(path, <<~CSV)
      Div,Date,HomeTeam,AwayTeam,FTHG,FTAG,FTR
      E0,13/08/2016,Hull,Leicester,2,1,H
      E0,13/08/2016,Man City,Sunderland,2,1,H
      E0,14/08/2016,Bournemouth,Man United,1,3,A
    CSV
    path
  end

  it "imports a season file that has no Time column" do
    result = Import::MatchImporter.new(path: timeless_csv, season_label: "2016/17").call

    expect(result).to be_success
    expect(result.created).to eq(3)
    expect(Match.count).to eq(3)
  end

  it "stores the published date without inventing a kickoff time" do
    Import::MatchImporter.new(path: timeless_csv, season_label: "2016/17").call

    dates = Match.order(:kickoff_at).pluck(:kickoff_at).map { |t| t.utc.strftime("%Y-%m-%d") }

    expect(dates).to eq(%w[2016-08-13 2016-08-13 2016-08-14])
  end

  it "is idempotent for a timeless season" do
    Import::MatchImporter.new(path: timeless_csv, season_label: "2016/17").call
    result = Import::MatchImporter.new(path: timeless_csv, season_label: "2016/17").call

    expect(result.skipped).to eq(3)
    expect(Match.count).to eq(3)
  end
end
