require 'rails_helper'

# Fixture discovery across a date window for one ESPN league.
#
# The regression this file exists to prevent: on 2026-10-30 the Premier League
# was backfilled by calling `espn:ingest` once per date an operator chose. The
# league then held 80 completed matches to 25 October and a hole from 26 October
# to 20 November, even though ESPN served those fixtures the whole time. Every
# individual request had succeeded, so the ledger showed 58 green runs and no
# signal that anything was missing.
#
# These specs run the real reconciler against the real tables; only the HTTP
# transport is replaced, so they prove the write path, the idempotency rule and
# the precedence rules together.
RSpec.describe Sync::EspnDiscoverySynchronizer do
  let(:competition) { Competition.find_or_create_by!(code: 'E0') { |c| c.name = 'Premier League' } }
  let!(:season) do
    Season.find_or_create_by!(competition: competition, name: '2026/27') do |s|
      s.start_date = Date.new(2026, 7, 1)
      s.end_date = Date.new(2027, 6, 30)
    end
  end
  let!(:arsenal) { Team.find_or_create_by!(name: 'Arsenal') { |t| t.normalized_name = Team.normalize('Arsenal') } }
  let!(:chelsea) { Team.find_or_create_by!(name: 'Chelsea') { |t| t.normalized_name = Team.normalize('Chelsea') } }
  let!(:fulham) { Team.find_or_create_by!(name: 'Fulham') { |t| t.normalized_name = Team.normalize('Fulham') } }
  let!(:spurs) { Team.find_or_create_by!(name: 'Tottenham') { |t| t.normalized_name = Team.normalize('Tottenham') } }

  before do
    { '1' => arsenal, '2' => chelsea, '3' => fulham, '4' => spurs }.each do |provider_id, team|
      ExternalIdentifier.create!(provider: 'espn', external_id: provider_id, team: team)
    end
  end

  def event(id:, date:, home:, away:, state: 'pre', status: 'STATUS_SCHEDULED', home_score: nil, away_score: nil)
    {
      'id' => id,
      'date' => date,
      'season' => { 'year' => 2026 },
      'competitions' => [{
        'status' => { 'type' => { 'name' => status, 'state' => state, 'completed' => state == 'post' } },
        'competitors' => [
          { 'homeAway' => 'home', 'score' => home_score,
            'team' => { 'id' => home, 'displayName' => 'home' } },
          { 'homeAway' => 'away', 'score' => away_score,
            'team' => { 'id' => away, 'displayName' => 'away' } }
        ]
      }]
    }
  end

  # An ESPN client double that serves the same event map for any window.
  #
  # The block's parameter names are NOT `from_date`/`to_date`. Inside the block a
  # parameter of that name shadows the helper of the same name, so a later bare
  # `to_date` call becomes `to_date.()` on a Date — "wrong number of arguments
  # (given 0, expected 1)". Copying the values into differently named locals first
  # keeps the block unambiguous.
  def client_for(events_by_date)
    client = instance_double(Import::EspnClient)
    allow(client).to receive(:scoreboard_dates) do |league:, from_date:, to_date:|
      first_day = from_date
      last_day = to_date
      days = {}
      collected = []
      day = first_day
      while day <= last_day
        events = Array(events_by_date[day.strftime('%Y%m%d')])
        days[day.strftime('%Y%m%d')] = events.size
        collected.concat(events)
        day += 1
      end
      Import::EspnClient::Result.new(events: collected, provider_ok: true, days: days)
    end
    client
  end

  # Ruby does NOT promote a bare hash literal to positional/keyword parameters:
  # `run_with('a' => 1)` is passed as keywords, which satisfy neither the
  # positional `events_by_date` nor the declared `first:`/`last:`. Every call site
  # below therefore passes braces. The window variants delegate here.
  def run_with(events_by_date, first: Date.new(2026, 10, 30), last: Date.new(2026, 11, 8))
    Sync::EspnDiscoverySynchronizer.new(client: client_for(events_by_date)).call(
      league: 'eng.1', internal_season: season, from_date: first, to_date: last
    )
  end

  # Runs discovery over an explicit window.
  def window(events_by_date, first, last)
    run_with(events_by_date, first: first, last: last)
  end

  describe 'discovering the gap' do
    it 'imports fixtures on days the previous date-by-date routine never requested' do
      run = run_with(
        {
          '20261101' => [event(id: '10', date: '2026-11-01T16:30Z', home: '1', away: '2',
                               state: 'post', status: 'STATUS_FULL_TIME', home_score: '2', away_score: '1')],
          '20261107' => [event(id: '11', date: '2026-11-07T15:00Z', home: '3', away: '4')]
        }
      )

      expect(run).to be_succeeded
      expect(run.created).to eq(2)
      expect(season.matches.where(kickoff_at: Date.new(2026, 11, 7)..Date.new(2026, 11, 7).end_of_day).count).to eq(1)
      expect(season.matches.completed.count).to eq(1)
    end

    it 'records the days it searched so an empty day is distinguishable from a missed day' do
      run = run_with({ '20261107' => [event(id: '11', date: '2026-11-07T15:00Z', home: '3', away: '4')] })

      expect(run.details['days_with_events']).to eq('20261107' => 1)
      expect(run.details['from']).to eq('2026-10-30')
      expect(run.details['to']).to eq('2026-11-08')
    end

    it 'is idempotent: the same window a second time creates nothing' do
      events = { '20261107' => [event(id: '11', date: '2026-11-07T15:00Z', home: '3', away: '4')] }
      run_with(events)
      second = run_with(events)

      expect(second).to be_succeeded
      expect(second.created).to eq(0)
      expect(second.skipped).to eq(1)
      expect(season.matches.count).to eq(1)
    end

    it 'never downgrades a completed result that the provider later reports as scheduled' do
      Match.create!(competition: competition, season: season, home_team: fulham, away_team: spurs,
                    kickoff_at: Time.utc(2026, 11, 7, 15), status: 'completed',
                    home_score: 2, away_score: 0)
      ExternalIdentifier.create!(provider: 'espn', external_id: '11', match: Match.last)

      run = run_with({ '20261107' => [event(id: '11', date: '2026-11-07T15:00Z', home: '3', away: '4')] })

      expect(Match.last.reload.status).to eq('completed')
      expect([Match.last.home_score, Match.last.away_score]).to eq([2, 0])
      expect(run.details['conflicts']).to eq(1)
    end

    it 'counts a rejected row when a provider team has no mapping, and creates nothing' do
      run = run_with({ '20261107' => [event(id: '99', date: '2026-11-07T15:00Z', home: '77', away: '78')] })

      expect(run).to be_succeeded
      expect(run.rejected).to eq(1)
      expect(season.matches.count).to eq(0)
    end
  end

  describe 'season completeness' do
    it 'does not move a fixture into a season ESPN contradicts' do
      # ESPN serves the event for that date under its own season year. When it
      # says 2025, a row aimed at 2026/27 must not be written — that mismatch is
      # how genuine fixtures were moved between seasons during the backfill.
      foreign = event(id: '77', date: '2026-11-07T15:00Z', home: '1', away: '2')
      foreign['season'] = { 'year' => 2025 }

      run = run_with({ '20261107' => [foreign] })

      expect(run.created).to eq(0)
      expect(season.matches.count).to eq(0)
    end

    it 'still imports an event that states no season at all' do
      # Refusing these would silently drop real fixtures.
      bare = event(id: '78', date: '2026-11-07T15:00Z', home: '1', away: '2')
      bare.delete('season')

      run = run_with({ '20261107' => [bare] })

      expect(run.created).to eq(1)
    end
    it 'does not fetch a window that starts after the season ends' do
      client = instance_double(Import::EspnClient)
      expect(client).not_to receive(:scoreboard_dates)

      run = Sync::EspnDiscoverySynchronizer.new(client: client).call(
        league: 'eng.1', internal_season: season,
        from_date: Date.new(2027, 7, 1), to_date: Date.new(2027, 7, 10)
      )

      expect(run).to be_succeeded
      expect(run.details['deferred']).to match(/outside the 2026\/27 season/i)
      expect(run.fetched).to eq(0)
    end

    it 'clips a window that straddles the end of the season instead of importing next season' do
      captured = nil
      client = instance_double(Import::EspnClient)
      allow(client).to receive(:scoreboard_dates) do |league:, from_date:, to_date:|
        captured = [from_date, to_date]
        Import::EspnClient::Result.new(events: [], provider_ok: true, days: {})
      end

      Sync::EspnDiscoverySynchronizer.new(client: client).call(
        league: 'eng.1', internal_season: season,
        from_date: Date.new(2027, 5, 20), to_date: Date.new(2027, 8, 20)
      )

      expect(captured).to eq([Date.new(2027, 5, 20), Sync::SeasonWindow.end_of_season(season.name)])
    end
  end
end
