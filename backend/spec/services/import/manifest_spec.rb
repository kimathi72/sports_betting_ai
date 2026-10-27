require 'rails_helper'

# A manifest is the operator's explicit statement of "these files, under these
# seasons". It exists so a multi-season run is reviewable BEFORE anything is
# enqueued: every entry names its own season label, and contradictory or
# duplicated entries are rejected rather than guessed at.
#
# The manifest never infers a season from a fixture date. A file's contents say
# when a match was played, not which season the operator meant, and guessing at a
# season boundary silently attaches history to the wrong season.
RSpec.describe Import::Manifest do
  # Manifest validation applies the same import-path allowlist as the job, so the
  # scratch directory is registered through the supported override rather than by
  # weakening the allowlist for real runs.
  around do |example|
    Dir.mktmpdir('manifest_spec') do |dir|
      original = ENV.fetch('IMPORT_ALLOWED_ROOTS', nil)
      ENV['IMPORT_ALLOWED_ROOTS'] = [original, dir].compact.join(File::PATH_SEPARATOR)
      @dir = dir
      example.run
    ensure
      original.nil? ? ENV.delete('IMPORT_ALLOWED_ROOTS') : ENV['IMPORT_ALLOWED_ROOTS'] = original
    end
  end

  def file(name = 'season.csv', body = "Div,Date,Time,HomeTeam,AwayTeam,FTHG,FTAG,FTR\n")
    path = File.join(@dir, name)
    File.write(path, body)
    path
  end

  # The manifest is built from plain data so it can come from a YAML file, a CLI
  # argument or a future API without changing the type.
  def build(entries)
    described_class.new(entries: entries)
  end

  describe 'a valid manifest' do
    it 'accepts one entry per season' do
      manifest = build([
                         { path: file('a.csv'), season: '2024/25', competition: 'E0' },
                         { path: file('b.csv'), season: '2025/26', competition: 'E0' },
                       ])

      expect(manifest).to be_valid
      expect(manifest.entries.length).to eq(2)
    end

    it 'normalises each entry into an explicit, immutable record' do
      manifest = build([{ path: file, season: '2024/25', competition: 'E0' }])

      entry = manifest.entries.first
      expect(entry.season_label).to eq('2024/25')
      expect(entry.competition_code).to eq('E0')
      expect(entry.provider).to eq('football_data')
      expect(entry.path).to eq(File.realpath(file))
      expect(entry).to be_frozen
    end

    it 'requires an explicit season label on every entry' do
      manifest = build([{ path: file, competition: 'E0' }])

      expect(manifest).not_to be_valid
      expect(manifest.errors.join(' ')).to match(/season/i)
    end

    it 'rejects a season label it cannot recognise' do
      manifest = build([{ path: file, season: 'last year', competition: 'E0' }])

      expect(manifest).not_to be_valid
      expect(manifest.errors.join(' ')).to match(/season/i)
    end

    it 'rejects an entry without a competition code' do
      manifest = build([{ path: file, season: '2024/25' }])

      expect(manifest).not_to be_valid
      expect(manifest.errors.join(' ')).to match(/competition/i)
    end

    it 'rejects a path that does not exist' do
      manifest = build([{ path: File.join(@dir, 'missing.csv'), season: '2024/25', competition: 'E0' }])

      expect(manifest).not_to be_valid
      expect(manifest.errors.join(' ')).to match(/not found|missing/i)
    end

    it 'rejects a path outside the approved import directory' do
      manifest = build([{ path: '/etc/passwd', season: '2024/25', competition: 'E0' }])

      expect(manifest).not_to be_valid
      expect(manifest.errors.join(' ')).to match(/outside|allowed|permitted/i)
    end
  end

  describe 'duplicates and contradictions' do
    it 'rejects the same season appearing twice for one competition' do
      manifest = build([
                         { path: file('a.csv'), season: '2024/25', competition: 'E0' },
                         { path: file('b.csv'), season: '2024/25', competition: 'E0' },
                       ])

      expect(manifest).not_to be_valid
      expect(manifest.errors.join(' ')).to match(/duplicate/i)
    end

    it 'rejects the same file appearing twice' do
      path = file('shared.csv')

      manifest = build([
                         { path: path, season: '2024/25', competition: 'E0' },
                         { path: path, season: '2025/26', competition: 'E0' },
                       ])

      expect(manifest).not_to be_valid
      expect(manifest.errors.join(' ')).to match(/duplicate|same file/i)
    end

    it 'allows the same season label in two different competitions' do
      manifest = build([
                         { path: file('a.csv'), season: '2024/25', competition: 'E0' },
                         { path: file('b.csv'), season: '2024/25', competition: 'E1' },
                       ])

      expect(manifest).to be_valid
    end

    it 'rejects an empty manifest' do
      expect(build([])).not_to be_valid
    end
  end

  describe '.from_yaml' do
    def yaml_file(contents)
      path = File.join(@dir, 'manifest.yml')
      File.write(path, contents)
      path
    end

    it 'loads a valid manifest' do
      yaml = yaml_file(<<~YAML)
        - path: #{file('a.csv')}
          season: "2024/25"
          competition: E0
      YAML

      manifest = described_class.from_yaml(yaml)

      expect(manifest).to be_valid
      expect(manifest.entries.first.season_label).to eq('2024/25')
    end

    it 'reports a missing manifest file without raising' do
      manifest = described_class.from_yaml(File.join(@dir, 'nope.yml'))

      expect(manifest).not_to be_valid
      expect(manifest.errors.join(' ')).to match(/not found|missing/i)
    end

    it 'reports invalid YAML instead of raising a parse error' do
      manifest = described_class.from_yaml(yaml_file(": : :\n  - [unclosed\n"))

      expect(manifest).not_to be_valid
      expect(manifest.errors.join(' ')).to match(/yaml|manifest/i)
    end

    it 'rejects a manifest that is not a list' do
      manifest = described_class.from_yaml(yaml_file("season: 2024/25\n"))

      expect(manifest).not_to be_valid
    end
  end

  describe 'path resolution' do
    it 'rejects a relative path, which is ambiguous in a container' do
      manifest = build([{ path: 'relative.csv', season: '2024/25', competition: 'E0' }])

      expect(manifest).not_to be_valid
      expect(manifest.errors.join(' ')).to match(/absolute/i)
    end

    it 'resolves a symlink to its real path' do
      target = file('target.csv')
      link = File.join(@dir, 'link.csv')
      File.symlink(target, link)

      manifest = build([{ path: link, season: '2024/25', competition: 'E0' }])
      # The real path is used, so a later change of the symlink cannot redirect
      # the import to a different file.
      expect(manifest.entries.first.path).to eq(File.realpath(target))
    end
  end
end
