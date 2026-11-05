module Sync
  # Shared machinery for the daily fixture and result synchronizations.
  #
  # Both jobs do the same four things and differ only in what they import:
  #
  #   1. open a ledger run (which also refuses to start a second concurrent run),
  #   2. refresh the provider's current-season CSV,
  #   3. hand it to the existing importer — the SAME importer used by the
  #      historical backfill, so status transitions, duplicate protection and
  #      conflict handling cannot drift between the two paths,
  #   4. close the run with counts, or with a classified error.
  #
  # Errors are classified rather than dumped, because the distinction decides
  # what happens next: `transient` should be retried by the queue, `permanent`
  # must not be (retrying a 404 a hundred times is a retry storm against a
  # provider that will never answer), and `configuration` needs a human.
  class BaseSynchronizer
    class TransientError < StandardError; end
    class PermanentError < StandardError; end
    class ConfigurationError < StandardError; end

    attr_reader :kind

    def initialize(downloader: nil, importer_class: Import::MatchImporter)
      @kind = self.class::KIND
      @downloader = downloader
      @importer_class = importer_class
    end

    # Returns the finished SyncRun. Never raises for provider failures — the run
    # row is the report, and a raised exception out of a scheduler job is how
    # failures become invisible.
    def call(trigger: 'schedule', seasons: nil, force: false)
      run = Sync::SyncRun.start!(kind: kind, trigger: trigger)
      started = Time.current

      # A subclass may decide the provider provably cannot have published anything
      # new yet. Returning early still closes the run, so "nothing to do" is
      # visible in the ledger rather than looking like a run that never happened.
      # An explicit `seasons:` argument means the caller wants the import anyway.
      reason = seasons.nil? ? deferral_reason : nil
      if reason
        run.finish!(status: 'succeeded', details: { deferred: reason })
        Rails.logger.info("[sync:#{kind}] deferred: #{reason}")
        return run
      end

      plan = seasons || seasons_to_sync
      path = download(plan, force: force)

      result = import(path)

      run.finish!(
        status: result.success? ? 'succeeded' : 'failed',
        fetched: result.processed,
        created: result.created,
        updated: result.updated,
        skipped: result.skipped,
        rejected: result.rejected,
        error: failure_text(result),
        details: {
          seasons: Array(plan),
          file: File.basename(path),
          checksum: checksum(path),
          waited_seconds: (Time.current - started).to_i,
          failures: result.errors.first(5)
        }
      )
      run
    rescue Sync::SyncRun::AlreadyRunning => e
      # Not an error: refusing to overlap is the designed outcome. Surfaced so the
      # job log says why nothing happened instead of looking like a silent no-op.
      Rails.logger.info("[sync:#{kind}] skipped, already running: #{e.message}")
      raise
    rescue ConfigurationError, PermanentError, Import::CsvDownloader::Unavailable => e
      close_failed(run, e, status: 'failed')
    rescue Import::CsvDownloader::TransientError, Net::OpenTimeout, Net::ReadTimeout, IOError => e
      close_failed(run, e, status: 'failed')
    rescue StandardError => e
      close_failed(run, e, status: 'failed')
    end

    private

    # Hook: nil means "run now". The default always runs; a synchronizer overrides
    # this to skip a provider call that provably cannot return new data.
    def deferral_reason
      nil
    end

    # Seasons this deployment synchronizes: the one containing today, plus the
    # previous one for the first weeks of a new season, when late results and
    # rearranged fixtures still land in the old file.
    def seasons_to_sync
      current = Sync::SeasonWindow.current_label(at: Time.current)
      previous = Sync::SeasonWindow.previous_label(at: Time.current)
      [previous, current].compact.uniq
    end

    def download(seasons, force:)
      downloader = @downloader || Import::CsvDownloader.new(
        destination_dir: Import::CsvDownloader::DEFAULT_DESTINATION,
        # A daily refresh MUST overwrite: the whole point is to pick up new
        # results in a file that already exists on disk.
        overwrite: true
      )

      results = downloader.download(seasons: seasons)
      results.each do |result|
        Rails.logger.info(
          "[sync:#{kind}] #{result.season} #{result.division}: #{result.status} " \
          "#{result.file_path} (#{result.size} bytes, time column: #{result.has_time_column})"
        )
      end

      # Import the CURRENT season file. The previous season is refreshed for
      # completeness but its rows are already complete; importing both would
      # double the work for no new data.
      current = results.last
      raise PermanentError, "provider returned no files for #{Array(seasons).join(', ')}" if current.nil?

      current.file_path
    end

    def import(path)
      @importer_class.new(path: path, season_label: season_label_for(path)).call
    end

    def season_label_for(path)
      code = File.basename(path.to_s).split('_').first.to_s
      Sync::SeasonWindow.label_from_code(code)
    end

    def failure_text(result)
      return nil if result.success?

      result.errors.map { |e| e[:message] || e['message'] }.compact.first(5).join('; ')
    end

    def checksum(path)
      Digest::SHA256.file(path).hexdigest
    rescue StandardError
      nil
    end

    def close_failed(run, error, status:)
      message = "#{error.class.name.split('::').last}: #{error.message}"
      Rails.logger.error("[sync:#{kind}] failed: #{message}")

      if run&.persisted? && run.running?
        run.finish!(status: status, error: message,
                    details: { error_class: error.class.name })
      end
      run
    end
  end
end
