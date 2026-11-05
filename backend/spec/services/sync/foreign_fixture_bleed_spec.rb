require "rails_helper"

# Repairs ESPN fixtures filed into a season they do not belong to.
#
# WHAT HAPPENED
# -------------
# `espn:discover[eng.2,2026/27]` resolved the target season by NAME, so it selected
# the Premier League's season and wrote Championship fixtures into it under
# competition E0: 407 scheduled rows and 29 rows marked "completed" for matches
# dated in 2027.
#
# WHAT THESE SPECS PIN
# --------------------
# The removal must be surgical. It may only select ESPN-only rows that are
# impossible on their own terms — an implausible kickoff hour, or a result for a
# match that has not been played. A completed result, a football-data row, or any
# plausible fixture must survive.
RSpec.describe Sync::ForeignFixtureBleed do
  let(:competition) { Competition.find_or_create_by!(code: "E0B") { |c| c.name = "Bleed Test League" } }
  let!(:season) do
    Season.find_or_create_by!(competition: competition, name: "2030/31") do |s|
      s.start_date = Date.new(2030, 7, 1)
      s.end_date = Date.new(2031, 6, 30)
    end
  end
  let!(:home) { Team.find_or_create_by!(name: "Bleed Home") { |t| t.normalized_name = "bleed home" } }
  let!(:away) { Team.find_or_create_by!(name: "Bleed Away") { |t| t.normalized_name = "bleed away" } }

  def make(kickoff:, status: "scheduled", espn_id: nil, fd: false)
    m = Match.create!(competition: competition, season: season, home_team: home,
                      away_team: away, kickoff_at: kickoff, status: status,
                      home_score: status == "completed" ? 1 : nil,
                      away_score: status == "completed" ? 0 : nil)
    ExternalIdentifier.create!(provider: "espn", external_id: espn_id, match: m) if espn_id
    ExternalIdentifier.create!(provider: "football_data", external_id: "fd-#{m.id}", match: m) if fd
    m
  end

  it "selects an ESPN-only row marked completed for a match still in the future" do
    bleed = make(kickoff: Time.current + 60.days, status: "completed", espn_id: "9002")

    expect(described_class.candidates(season).map(&:id)).to include(bleed.id)
  end

  it "keeps a plausible scheduled fixture" do
    genuine = make(kickoff: Time.utc(2030, 11, 2, 15, 0), espn_id: "9003")

    expect(described_class.candidates(season).map(&:id)).not_to include(genuine.id)
  end

  it "keeps a completed result whose kickoff is in the past" do
    real = make(kickoff: Time.current - 7.days, status: "completed", espn_id: "9004")

    expect(described_class.candidates(season).map(&:id)).not_to include(real.id)
  end

  it "never selects a row with football-data provenance" do
    trusted = make(kickoff: Time.current + 60.days, status: "completed", espn_id: "9005", fd: true)

    expect(described_class.candidates(season).map(&:id)).not_to include(trusted.id)
  end

  it "never selects a row without an ESPN identifier" do
    make(kickoff: Time.current + 60.days, status: "completed")

    expect(described_class.candidates(season)).to be_empty
  end

  it "refuses to delete anything: the removal path is retired" do
    # The classifier identified zero of the 139 confirmed contaminated rows, so
    # acting on it would delete real fixtures while leaving the damage in place.
    # `call` must raise for every argument combination, including dry_run: false.
    make(kickoff: Time.current + 90.days, status: "completed", espn_id: "9100")

    expect { described_class.new(season).call(dry_run: false) }
      .to raise_error(Sync::ForeignFixtureBleed::Retired, /retired/)

    expect { described_class.new(season).call }
      .to raise_error(Sync::ForeignFixtureBleed::Retired)
  end

  it "deletes no match when the retired path is invoked" do
    make(kickoff: Time.current + 90.days, status: "completed", espn_id: "9101")
    before = Match.count

    expect { described_class.new(season).call(dry_run: false) }
      .to raise_error(Sync::ForeignFixtureBleed::Retired)

    expect(Match.count).to eq(before)
  end

  it "still exposes a read-only candidate list for forensics" do
    make(kickoff: Time.current + 90.days, status: "completed", espn_id: "9102")
    expect(described_class.candidates(season)).to be_an(Array)
  end
end
