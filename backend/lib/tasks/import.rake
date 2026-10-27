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
  desc 'Import a single football-data.co.uk CSV file (path, season label)'
  task :football_data, %i[path season] => :environment do |_task, args|
    result = Import::Command.new(path: args[:path], season_label: args[:season]).call

    puts result.output

    # `exit` rather than `abort` so the message above is already printed and no
    # extra status text is mixed into operator output.
    exit(result.exit_status) unless result.success?
  end
end
