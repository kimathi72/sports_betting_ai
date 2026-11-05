require 'rails_helper'

# The result synchronizer must not spend a request against a rate-limited source
# to re-import a file that cannot yet contain the result it is looking for.
#
# A fixture that kicked off "now" is still in its publication delay, so a run at
# that moment would report success with zero new results — indistinguishable, to
# an operator reading the ledger, from a broken import. Deferring is recorded as a
# succeeded run carrying the reason, so the intent is visible.
RSpec.describe Sync::ResultSynchronizer do
  let(:competition) { Competition.create!(name: 'Premier League', code: 'EPL') }
  let(:season) { Season.create!(competition: competition, name: '2026/27') }
  let(:home) { Team.create!(name: 'Home') }
  let(:away) { Team.create!(name: 'Away') }

  def scheduled_match(kickoff_at)
    Match.create!(competition: competition, season: season, home_team: home,
                  away_team: away, kickoff_at: kickoff_at, status: 'scheduled')
  end

  it 'defers while the newest pending fixture is inside the publication window' do
    scheduled_match(30.minutes.ago)

    # Stubbed but never expected to be used: a spy records whether the deferral
    # really prevented the provider request.
    downloader = instance_double(Import::CsvDownloader)
    allow(downloader).to receive(:download)
    run = described_class.new(downloader: downloader).call(trigger: 'schedule')

    expect(run).to be_succeeded
    expect(run.details['deferred']).to include('results are published after')
    # The decisive assertion: no provider request was made.
    expect(downloader).not_to have_received(:download)
  end

  it 'runs when the pending fixture finished long enough ago' do
    scheduled_match(6.hours.ago)

    downloader = instance_double(Import::CsvDownloader)
    allow(downloader).to receive(:download)
      .and_raise(Import::CsvDownloader::Unavailable, 'HTTP 404 for 2627/E0.csv')
    run = described_class.new(downloader: downloader).call(trigger: 'schedule')

    expect(downloader).to have_received(:download)
    expect(run).to be_failed
  end

  it 'runs when there is no pending fixture to wait for' do
    downloader = instance_double(Import::CsvDownloader)
    allow(downloader).to receive(:download)
      .and_raise(Import::CsvDownloader::Unavailable, 'HTTP 404 for 2627/E0.csv')
    described_class.new(downloader: downloader).call(trigger: 'schedule')

    expect(downloader).to have_received(:download)
  end

  it 'does not defer when the caller passes explicit seasons' do
    scheduled_match(30.minutes.ago)

    downloader = instance_double(Import::CsvDownloader)
    allow(downloader).to receive(:download)
      .and_raise(Import::CsvDownloader::Unavailable, 'HTTP 404 for 2627/E0.csv')
    described_class.new(downloader: downloader).call(trigger: 'manual', seasons: ['2026/27'])

    expect(downloader).to have_received(:download)
  end

  it 'ignores a fixture that kicked off in the future' do
    scheduled_match(2.days.from_now)

    downloader = instance_double(Import::CsvDownloader)
    allow(downloader).to receive(:download)
      .and_raise(Import::CsvDownloader::Unavailable, 'HTTP 404 for 2627/E0.csv')
    described_class.new(downloader: downloader).call(trigger: 'schedule')

    expect(downloader).to have_received(:download)
  end
end
