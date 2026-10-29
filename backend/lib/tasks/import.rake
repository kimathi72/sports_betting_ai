namespace :import do
  # Import one football-data.co.uk CSV file into the canonical schema.
  #
  #   bundle exec rake "import:football_data[/data/fixtures/foo.csv,2024/25]"
  #
  # Both arguments are required. The season label is the operator's explicit
  # choice and is never inferred from the fixture dates.
  #
  # The task is a thin wrapper: Import::Command does the validation, runs the
  # importer and formats the report. A failed import exits non-zero so a script
  # or CI step can detect it.
  desc "Import a single football-data.co.uk CSV file (path, season label)"
  task :football_data, %i[path season] => :environment do |_task, args|
    result = Import::Command.new(path: args[:path], season_label: args[:season]).call

    puts result.output

    # `exit` rather than `abort` so the message above is already printed and no
    # extra status text is mixed into operator output.
    exit(result.exit_status) unless result.success?
  end

  # Import historical data from a YAML manifest.
  #
  #   bundle exec rake "import:historical[/data/fixtures/history_manifest.yml,2024/25]"
  #
  # Both arguments are required. The season label is used for auditing and is
  # never inferred from the manifest contents.
  #
  # The task is a thin wrapper: Import::HistoryCommand does the validation,
  # runs the orchestrator and formats the report. A failed import exits non-zero
  # so a script or CI step can detect it.
    desc "Import historical data from a YAML manifest (manifest_path, season label)"
    task :historical, %i[manifest_path season] => :environment do |_task, args|
      result = Import::HistoryCommand.new(
        path: args[:manifest_path], season_label: args[:season]
      ).call
      puts result.output
      # `exit` rather than `abort` so the message above is already printed and no
      # extra status text is mixed into operator output.
      exit(result.exit_status) unless result.success?
    end

    # Download raw football-data.co.uk CSV files into data/raw/.
    #
    #   bundle exec rake "import:download[2024/25]"
    #   bundle exec rake "import:download[2024/25,2025/26]"
    #   DIVISION=E1 bundle exec rake "import:download[2024/25]"
    #
    # Seasons must be listed explicitly: there is deliberately no "download
    # everything" default, because that would fetch the whole archive (and hammer
    # a free source) on a single command. Set FORCE=1 to replace an existing file.
    #
    # A failure exits non-zero so a script or CI step can detect it.
    desc "Download raw football-data.co.uk CSVs (season[,season...]) into data/raw"
    task :download, %i[seasons] => :environment do |_task, args|
      # Rake splits `task[a,b,c]` on commas: `args[:seasons]` receives only "a"
      # and the rest arrive in `args.extras`. Reading both is what makes a
      # multi-season request actually download every season.
      seasons = [args[:seasons], *args.extras].join(',').split(/[,\s]+/).reject(&:empty?)

      if seasons.empty?
        warn "usage: rake \"import:download[2024/25,2025/26]\" [DIVISION=E0] [FORCE=1]"
        exit 1
      end

      division = ENV.fetch("DIVISION", "E0")
      # `web` mounts /data read-only so importers cannot modify fixtures. Downloads
      # therefore need a writable target: pass RAW_IMPORT_DIR=/app/tmp/raw (or any
      # writable directory) when running inside that container.
      destination = ENV.fetch("RAW_IMPORT_DIR", Import::CsvDownloader::DEFAULT_DESTINATION)
      # Construction validates the division, so it is guarded too: an operator
      # typo must be one clean line and a non-zero status, not a backtrace.
      begin
        downloader = Import::CsvDownloader.new(
          destination_dir: destination,
          division: division,
          overwrite: ENV["FORCE"] == "1"
        )
      rescue Import::CsvDownloader::InvalidInput => e
        warn "invalid input: #{e.message}"
        exit 1
      end

      failures = 0

      seasons.each do |season|
        begin
          result = downloader.download_one(season: season)

          if result.already_present?
            puts "already present: #{season} #{division} -> #{result.file_path}"
          else
            puts "downloaded: #{season} #{division} -> #{result.file_path} " \
                 "(#{result.size} bytes, sha256 #{result.checksum[0, 12]}...)"
            puts "  no Time column (older season)" if result.missing_time_column?
          end
        rescue Import::CsvDownloader::InvalidInput => e
          warn "invalid input: #{e.message}"
          failures += 1
        rescue Import::CsvDownloader::Unavailable => e
          warn "unavailable: #{e.message}"
          failures += 1
        rescue Import::CsvDownloader::InvalidContent => e
          warn "rejected content: #{e.message}"
          failures += 1
        rescue Import::CsvDownloader::TransientError => e
          warn "download failed: #{e.message}"
          failures += 1
        rescue StandardError => e
          # An unexpected failure is still reported as one clean line: an operator
          # needs the reason, not a Ruby backtrace. The exception class is kept
          # because it is the actionable part.
          warn "unexpected failure: #{e.class}: #{e.message}"
          failures += 1
        end
      end

      if failures.positive?
        warn "#{failures} of #{seasons.length} season(s) failed"
        exit 1
      end

      puts "#{seasons.length} season(s) ready in #{destination}"
    end
  end
