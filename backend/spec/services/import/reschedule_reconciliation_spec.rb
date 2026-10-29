require 'rails_helper'

# Re-importing an updated provider file must keep the stored fixture in step
# with reality. The provider rewrites the SAME row when a fixture moves, so the
# only way to notice is to compare the stored kickoff with the incoming one.
#
# What matters, and why:
#   - a rescheduled fixture must actually move. Silently skipping it would leave
#     a prediction scheduled against a kickoff that no longer exists.
#   - a reschedule is NOT a new match. Creating a second record for the same
#     fixture would double-count it in training and double it in evaluation.
#   - a completed result must never be overwritten by a fixture-only row, and a
#     reschedule must never disturb a stored result.
#   - the provider key includes kickoff time, so a moved fixture arrives under a
#     NEW key. Reconciliation therefore relies on the match identity, not the key
#     alone: the old identifier must be preserved so history stays auditable.
RSpec.describe 'Import::MatchImporter reschedule reconciliation' do
  let(:season_label) { '2024/25' }
  let(:home_name) { 'Reschedule Home' }
  let(:away_name) { 'Reschedule Away' }

  let(:original_kickoff) { Time.utc(2026, 8, 16, 15, 0) }
  let(:moved_kickoff) { Time.utc(2026, 8, 17, 19, 45) }

  # The importer creates competitions, seasons and teams by name, so this spec
  # seeds nothing: it exercises the real resolution path instead of a factory
  # shortcut that would bypass the code under test.
  def csv_for(date:, time:)
    dir = Dir.mktmpdir
    path = File.join(dir, 'reschedule.csv')
    File.write(path, <<~CSV)
      Div,Date,Time,HomeTeam,AwayTeam,FTHG,FTAG,FTR
      E0,#{date},#{time},#{home_name},#{away_name},,,
    CSV
    path
  end

  def import(path)
    Import::MatchImporter.new(path: path, season_label: season_label).call
  end

  it 'moves a scheduled fixture when the provider publishes a new kickoff' do
    first = import(csv_for(date: '16/08/2026', time: '15:00'))
    expect(first).to be_success
    expect(Match.count).to eq(1)
    match = Match.first
    expect(match.kickoff_at).to eq(original_kickoff)

    second = import(csv_for(date: '17/08/2026', time: '19:45'))

    expect(second).to be_success
    expect(second.updated).to eq(1), 'a reschedule must be reported as an update, not a skip'
    expect(Match.count).to eq(1), 'a reschedule must not create a second fixture'
    expect(Match.first.reload.kickoff_at).to eq(moved_kickoff)
  end

  it 'is idempotent: re-importing the moved fixture changes nothing' do
    import(csv_for(date: '16/08/2026', time: '15:00'))
    import(csv_for(date: '17/08/2026', time: '19:45'))

    third = import(csv_for(date: '17/08/2026', time: '19:45'))

    expect(third).to be_success
    expect(third.skipped).to eq(1)
    expect(third.updated).to eq(0)
    expect(Match.count).to eq(1)
    expect(Match.first.kickoff_at).to eq(moved_kickoff)
  end

  it 'keeps the original provider identifier so history stays auditable' do
    import(csv_for(date: '16/08/2026', time: '15:00'))
    match = Match.first
    original_keys = ExternalIdentifier.where(match_id: match.id, provider: 'football_data')
                                      .pluck(:external_id)
    expect(original_keys).not_to be_empty

    import(csv_for(date: '17/08/2026', time: '19:45'))

    keys = ExternalIdentifier.where(match_id: match.id, provider: 'football_data')
                             .pluck(:external_id)
    expect(keys).to include(*original_keys), 'the previous identifier must be retained'
    expect(keys.length).to be >= 2, 'the new kickoff arrives under a new provider key'
  end

  it 'does not match a fixture to an unrelated club' do
    import(csv_for(date: '16/08/2026', time: '15:00'))

    # Same date, different clubs: this is a DIFFERENT fixture and must be created,
    # not folded into the existing record by a looseness in the fallback.
    other = csv_for(date: '16/08/2026', time: '15:00')
    File.write(other, <<~CSV)
      Div,Date,Time,HomeTeam,AwayTeam,FTHG,FTAG,FTR
      E0,16/08/2026,15:00,Some Other Home,Some Other Away,,,
    CSV
    import(other)

    expect(Match.count).to eq(2)
  end

  it 'does not match the reverse fixture (same clubs, home and away swapped)' do
    import(csv_for(date: '16/08/2026', time: '15:00'))

    reversed = csv_for(date: '16/08/2026', time: '15:00')
    File.write(reversed, <<~CSV)
      Div,Date,Time,HomeTeam,AwayTeam,FTHG,FTAG,FTR
      E0,16/08/2026,15:00,#{away_name},#{home_name},,,
    CSV
    import(reversed)

    expect(Match.count).to eq(2), 'a reversed fixture is a different match'
  end

  it 'does not disturb a stored result when the fixture row has no score' do
    import(csv_for(date: '16/08/2026', time: '15:00'))
    match = Match.first
    match.update!(status: 'completed', home_score: 2, away_score: 1)

    result = import(csv_for(date: '17/08/2026', time: '19:45'))

    expect(result).to be_success
    expect(match.reload.status).to eq('completed')
    expect([match.home_score, match.away_score]).to eq([2, 1])
  end

  it 'rejects a conflicting result for an already completed fixture' do
    import(csv_for(date: '16/08/2026', time: '15:00'))
    Match.first.update!(status: 'completed', home_score: 2, away_score: 1)

    conflicting = csv_for(date: '16/08/2026', time: '15:00')
    File.write(conflicting, <<~CSV)
      Div,Date,Time,HomeTeam,AwayTeam,FTHG,FTAG,FTR
      E0,16/08/2026,15:00,#{home_name},#{away_name},0,3,A
    CSV

    before = [Match.first.home_score, Match.first.away_score]
    result = import(conflicting)

    expect(result).to be_failure, 'a contradicting result must not be silently applied'
    expect([Match.first.reload.home_score, Match.first.away_score]).to eq(before)
  end
end
