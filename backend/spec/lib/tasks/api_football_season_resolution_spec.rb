require 'rails_helper'
require 'rake'

# API-Football must not resolve an internal season by name alone.
#
# THE DEFECT
# ----------
# `api_football.rake:64` used `Season.find_by(name: label)`. Season names are not
# unique across competitions — every competition has a "2026/27" — so the lookup
# returned whichever row came first. This is the same class of defect that put
# 139 Championship fixtures into the Premier League; it was fixed for ESPN and
# left in place for API-Football.
#
# THE FIX
# -------
# The task now requires the internal competition code (API-Football's own league
# ids are NOT our catalogue codes: 39 is the Premier League to them, "E0" to us).
# Resolution therefore goes code -> Competition -> Season, and the provider league
# id is carried separately for the request.
#
# No import is executed here: the synchronizer is stubbed, so no API quota is
# consumed and no fixture is written.
RSpec.describe 'api_football:ingest season resolution' do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  let!(:e0) { Competition.find_or_create_by!(code: 'E0') { |c| c.name = 'Premier League' } }
  let!(:e1) { Competition.find_or_create_by!(code: 'E1') { |c| c.name = 'Championship' } }
  let!(:e0_season) do
    Season.find_or_create_by!(competition: e0, name: '2026/27') do |s|
      s.start_date = Date.new(2026, 7, 1)
      s.end_date = Date.new(2027, 6, 30)
    end
  end
  let!(:e1_season) do
    Season.find_or_create_by!(competition: e1, name: '2026/27') do |s|
      s.start_date = Date.new(2026, 7, 1)
      s.end_date = Date.new(2027, 6, 30)
    end
  end

  def stub_sync
    received = nil
    allow_any_instance_of(Sync::ApiFootballFixtureSynchronizer).to receive(:call) do |_inst, kwargs|
      received = kwargs
      Sync::SyncRun.create!(kind: 'fixtures', trigger: 'manual', status: 'succeeded',
                            started_at: Time.current, finished_at: Time.current, details: {})
    end
    -> { received }
  end

  it 'resolves the season of the stated competition, not the first with that name' do
    captured = stub_sync
    Rake::Task['api_football:ingest'].reenable
    Rake::Task['api_football:ingest'].invoke('41', '2026', '2026/27', 'E1')

    expect(captured.call[:internal_season]).to eq(e1_season)
    expect(captured.call[:internal_season]).not_to eq(e0_season)
  end

  it 'passes the provider league id through unchanged for the request' do
    captured = stub_sync
    Rake::Task['api_football:ingest'].reenable
    Rake::Task['api_football:ingest'].invoke('39', '2026', '2026/27', 'E0')

    expect(captured.call[:league]).to eq('39')
    expect(captured.call[:internal_season]).to eq(e0_season)
  end

  it 'refuses when no competition code is given, instead of guessing by name' do
    stub_sync
    Rake::Task['api_football:ingest'].reenable
    expect { Rake::Task['api_football:ingest'].invoke('39', '2026', '2026/27') }
      .to raise_error(SystemExit)
  end

  it 'refuses a competition code that does not exist' do
    stub_sync
    Rake::Task['api_football:ingest'].reenable
    expect { Rake::Task['api_football:ingest'].invoke('39', '2026', '2026/27', 'ZZ9') }
      .to raise_error(SystemExit)
  end

  it 'refuses a competition that has no season of that name' do
    stub_sync
    Rake::Task['api_football:ingest'].reenable
    expect { Rake::Task['api_football:ingest'].invoke('39', '2026', '2027/28', 'E1') }
      .to raise_error(SystemExit)
  end

  it 'never resolves a season by name alone' do
    # Comments are stripped first: prose that explains the old defect must not
    # trip a guard, or the next person deletes the explanation to get green.
    source = File.read(Rails.root.join('lib/tasks/api_football.rake'))
    code = source.lines.reject { |line| line.strip.start_with?('#') }.join

    expect(code).not_to match(/Season\.find_by\(\s*name:/)
  end
end
