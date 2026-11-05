require 'rails_helper'

# The project ships two operator manifests, and they must not drift.
#
#   data/manifests/premier_league_history.yml  completed seasons, reproducible
#   data/manifests/premier_league_current.yml  the in-progress season only
#
# Splitting them is deliberate. A historical backfill should be reproducible and
# stable; the current season changes every week and may contain whatever the
# source has published so far. Mixing them means a backfill run silently picks up
# a moving target, and a report of "the history imported 4,260 matches" stops
# being reproducible a week later.
#
# These specs validate the committed files themselves — paths, season labels and
# the absence of overlap — without requiring the CSVs to be present, so they run
# anywhere. A separate check (skipped when files are absent) confirms the paths
# really point at downloaded files.
RSpec.describe 'committed import manifests' do
  MANIFESTS = Rails.root.join('..', 'data', 'manifests')
  HISTORY = MANIFESTS.join('premier_league_history.yml')
  CURRENT = MANIFESTS.join('premier_league_current.yml')
  MULTI = MANIFESTS.join('multi_league_history.yml')

  def load_manifest(path)
    YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
  end

  def season_keys(entries)
    entries.map { |entry| [entry['competition'], entry['season'].to_s] }
  end

  describe 'presence' do
    it 'ships a completed-history manifest' do
      expect(HISTORY).to exist
    end

    it 'ships a current-season manifest' do
      expect(CURRENT).to exist
    end
  end

  describe 'the history manifest' do
    subject(:entries) { load_manifest(HISTORY) }

    it 'covers completed seasons from 2015/16 to 2025/26' do
      expect(entries.map { |e| e['season'].to_s }).to eq(
        %w[2015/16 2016/17 2017/18 2018/19 2019/20 2020/21
           2021/22 2022/23 2023/24 2024/25 2025/26]
      )
    end

    it 'excludes the in-progress season' do
      expect(entries.map { |e| e['season'].to_s }).not_to include('2026/27')
    end

    it 'has no duplicate season entries' do
      expect(season_keys(entries).uniq.length).to eq(entries.length)
    end

    it 'names a season on every entry' do
      expect(entries).to all(include('season'))
    end
  end

  describe 'the current-season manifest' do
    subject(:entries) { load_manifest(CURRENT) }

    it 'contains exactly the in-progress season' do
      expect(entries.map { |e| e['season'].to_s }).to eq(['2026/27'])
    end

    it 'has no duplicate entries' do
      expect(season_keys(entries).uniq.length).to eq(entries.length)
    end
  end

  describe 'the two manifests together' do
    it 'never claim the same competition and season' do
      overlap = season_keys(load_manifest(HISTORY)) & season_keys(load_manifest(CURRENT))

      expect(overlap).to be_empty
    end

    it 'never reference the same file' do
      paths = (load_manifest(HISTORY) + load_manifest(CURRENT)).map { |e| e['path'] }

      expect(paths.uniq.length).to eq(paths.length)
    end
  end

  describe 'entry shape' do
    it 'uses the source season code embedded in each filename' do
      (load_manifest(HISTORY) + load_manifest(CURRENT)).each do |entry|
        filename = File.basename(entry['path'])
        expect(filename).to match(/\A\d{4}_#{Regexp.escape(entry['competition'])}\.csv\z/)
      end
    end

    it 'derives the same season code as the downloader' do
      (load_manifest(HISTORY) + load_manifest(CURRENT)).each do |entry|
        downloader = Import::CsvDownloader.new(
          destination_dir: '/tmp', division: entry['competition']
        )
        expected = File.basename(entry['path']).split('_').first

        expect(downloader.source_url(season: entry['season'].to_s)).to include("/#{expected}/")
      end
    end
  end

  describe 'downloaded files, when present' do
    it 'points every entry at a file that exists' do
      entries = load_manifest(HISTORY) + load_manifest(CURRENT)
      # Manifest paths are container paths; map them onto the repository data dir.
      repo_data = Rails.root.join('..', 'data').to_s

      entries.each do |entry|
        host_path = entry['path'].sub(%r{\A/data/}, "#{repo_data}/")
        skip "not downloaded: #{entry['path']}" unless File.exist?(host_path)

        expect(File.file?(host_path)).to be(true)
        expect(File.size(host_path)).to be > 0
      end
    end
  end
end

# The multi-competition backfill is a third, independent manifest. It exists
# because the Premier League is not the only competition the models are trained
# on, and it must obey the same shape rules as the others.
RSpec.describe 'the multi-league import manifest' do
  manifests = Rails.root.join('..', 'data', 'manifests')
  multi = manifests.join('multi_league_history.yml')

  def load_entries(path)
    YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
  end

  it 'exists' do
    expect(multi).to exist
  end

  it 'covers only completed seasons (2024/25 and 2025/26)' do
    entries = load_entries(multi)
    expect(entries.map { |e| e['season'].to_s }.uniq.sort).to eq(%w[2024/25 2025/26])
  end

  it 'covers the verified European divisions' do
    entries = load_entries(multi)
    expect(entries.map { |e| e['competition'] }.uniq.sort)
      .to eq(%w[B1 D1 E1 F1 I1 N1 P1 SC0 SP1 T1])
  end

  it 'never duplicates a competition and season' do
    entries = load_entries(multi)
    keys = entries.map { |e| [e['competition'], e['season'].to_s] }
    expect(keys.uniq.length).to eq(entries.length)
  end

  it 'never overlaps the Premier League manifests' do
    entries = load_entries(multi)
    other = %w[premier_league_history.yml premier_league_current.yml].flat_map do |name|
      load_entries(manifests.join(name)).map { |e| [e['competition'], e['season'].to_s] }
    end
    mine = entries.map { |e| [e['competition'], e['season'].to_s] }
    expect(mine & other).to be_empty
  end

  it 'names files the downloader can produce' do
    load_entries(multi).each do |entry|
      downloader = Import::CsvDownloader.new(
        destination_dir: '/tmp', division: entry['competition']
      )
      expected = File.basename(entry['path']).split('_').first
      expect(downloader.source_url(season: entry['season'].to_s)).to include("/#{expected}/")
      expect(File.basename(entry['path']))
        .to eq("#{expected}_#{entry['competition']}.csv")
    end
  end
end
