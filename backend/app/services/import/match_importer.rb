module Import
  # Imports one provider CSV file into the canonical schema, atomically.
  #
  # The importer is the only class that decides *when* to write. It owns the
  # batch transaction and delegates the "what does this row mean" question to the
  # adapter (via MatchRow) and the "which canonical records" question to the
  # ReferenceResolver. It contains no provider column names.
  #
  # ATOMICITY. Every row is persisted inside one transaction. A single rejected
  # row aborts the whole batch: raising `Abort` from inside the transaction block
  # rolls back everything this run wrote, including competitions, seasons, teams,
  # matches and the external identifiers created for the rows that were valid.
  # Catching an error *inside* the block and carrying on would commit the earlier
  # writes, which is exactly the partial import this class exists to prevent.
  #
  # IDEMPOTENCY. Nothing is created twice. Each row resolves through a
  # persistent ExternalIdentifier; a second identical run reuses every match and
  # reports it as `skipped`.
  #
  # CONFLICTS. A stored completed result is history and is never overwritten. An
  # incoming row that disagrees with it rejects the batch rather than replacing a
  # real score with a provider revision. A scheduled fixture receiving its first
  # result is the normal promotion path and is counted as `updated`.
  class MatchImporter
    # Raised to roll the batch back. It never escapes `call`.
    class Abort < StandardError
      attr_reader :message

      def initialize(message)
        @message = message
        super
      end
    end

    # A batch abort caused by a specific source row. Carrying the zero-based
    # index lets the failure be reported against the row an operator can find.
    class RowAbort < Abort
      attr_reader :index

      def initialize(message, index:)
        @index = index
        super(message)
      end
    end

    # Outcome of persisting one resolved row, used only inside the batch.
    Outcome = Struct.new(:kind, :match, keyword_init: true) do
      def created?
        kind == :created
      end

      def updated?
        kind == :updated
      end

      def skipped?
        kind == :skipped
      end
    end

    def initialize(path:, season_label:)
      @path = path.to_s
      @season_label = season_label.to_s
    end

    attr_reader :path, :season_label

    def call
      rows = read_rows
      return Result.success(input: 0) if rows.empty?

      parsed = parse_rows(rows)
      rejected = parsed.reject { |row_result| row_result.success? }
      return rejection_result(rows.length, rejected) unless rejected.empty?

      persist(parsed)
    rescue Abort => e
      file_failure(e)
    end

    private

    # A file-level problem (absent, empty, wrong header, unparseable) happens
    # before any transaction exists. It is still an `Abort`, so `call` reports it
    # the same way as a row rejection, but nothing was ever opened for writing.
    def read_rows
      CsvReader.read(path, required: FootballDataCoUkAdapter::REQUIRED_COLUMNS)
    rescue CsvReader::FileNotFound, CsvReader::EmptyFile, CsvReader::MissingHeaders,
           CsvReader::MalformedCsv => e
      raise Abort, "file could not be read: #{safe_message(e.message)}"
    end

    def file_failure(abort)
      Result.failure(
        input: 1,
        rejected: 1,
        errors: [Result.error(index: 0, message: abort.message)]
      )
    end

    # Parsing is done up front so an obviously malformed file never opens a
    # transaction. Row errors are collected, not raised, so every bad row is
    # reported at once.
    def parse_rows(rows)
      FootballDataCoUkAdapter.parse_all(rows)
    end

    # A parse failure aborts the batch just as a persistence failure does: no
    # subset of the file is imported. Every input row is therefore reported as
    # rejected, and each bad row carries its own actionable error so the operator
    # can fix them all in one pass.
    def rejection_result(input, rejected)
      errors = rejected.map do |row_result|
        message = row_result.error.to_s.presence || 'row could not be parsed'
        Result.error(index: row_result.index, message: safe_message(message))
      end

      Result.failure(input: input, rejected: input, errors: errors)
    end

    def persist(parsed)
      counters = { created: 0, updated: 0, skipped: 0 }

      ActiveRecord::Base.transaction do
        parsed.each do |row_result|
          outcome = persist_row(row_result)
          counters[outcome.kind] += 1
        end
      end

      Result.success(
        input: parsed.length,
        created: counters.fetch(:created),
        updated: counters.fetch(:updated),
        skipped: counters.fetch(:skipped)
      )
    rescue Abort => e
      # The transaction rolled back. Nothing was written, so no row may be
      # reported as created/updated/skipped: every row in the batch is rejected,
      # and the error names the row that caused the rollback.
      index = e.respond_to?(:index) ? e.index : 0
      Result.failure(
        input: parsed.length,
        rejected: parsed.length,
        errors: [Result.error(index: index, message: safe_message(e.message))]
      )
    end

    def persist_row(row_result)
      resolution = resolver.resolve_row(row_result.row, season_label: season_label)
      raise Abort, safe_message(resolution.error) unless resolution.success?

      # The resolver reports whether IT created the match. A match it reused was
      # already stored, so the row must be reconciled against that history.
      existing = resolution.created_record? ? nil : resolution.match
      kind = reconcile(existing, row_result.row)

      Outcome.new(kind: kind, match: resolution.match)
    rescue Abort => e
      raise RowAbort.new(e.message, index: row_result.index)
    rescue ActiveRecord::RecordNotUnique
      # A concurrent import holds the same mapping. Retrying the whole batch is
      # safe (the other run's work is then reused), but continuing here could
      # duplicate a match.
      raise RowAbort.new('concurrent import detected; retry the import', index: row_result.index)
    rescue ActiveRecord::RecordInvalid => e
      raise RowAbort.new(safe_message(e.record.errors.full_messages.to_sentence), index: row_result.index)
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
      raise RowAbort.new('could not be persisted because of a database error', index: row_result.index)
    end

    # Decides how an incoming row relates to what is already stored:
    #
    #   :created — no stored match for this fixture
    #   :updated — a scheduled/postponed fixture that now has a final result
    #   :skipped — the stored match already says exactly this
    #
    # A completed match that disagrees with the input is a conflict, and the
    # batch aborts. Overwriting it would silently replace an authoritative result.
    def reconcile(existing, row)
      return :created if existing.nil?

      if existing.status == Match::STATUS_COMPLETED && row.status == Match::STATUS_COMPLETED
        return :skipped if same_result?(existing, row)

        raise Abort, "completed result conflict: stored #{score_of(existing)} but the " \
                     "imported row says #{row.home_score}-#{row.away_score}"
      end

      if existing.status == Match::STATUS_COMPLETED
        # A completed match arriving as scheduled/postponed is a provider
        # regression. Keep the result and reject the row.
        raise Abort, "imported row would downgrade a completed match (#{score_of(existing)}) " \
                     'to ' + row.status.to_s
      end

      if row.status == Match::STATUS_COMPLETED
        promote(existing, row)
        return :updated
      end

      # Neither side has a result: keep the stored fixture, but apply a status
      # change that carries information (e.g. scheduled -> postponed).
      changed = existing.status != row.status
      if changed
        existing.update!(status: row.status)
        return :updated
      end

      :skipped
    end

    def promote(existing, row)
      existing.home_score = row.home_score
      existing.away_score = row.away_score
      existing.status = Match::STATUS_COMPLETED
      existing.kickoff_at = row.kickoff_at if row.kickoff_at
      existing.save!
    end

    def same_result?(existing, row)
      existing.home_score == row.home_score && existing.away_score == row.away_score
    end

    def score_of(match)
      "#{match.home_score}-#{match.away_score}"
    end

    def resolver
      @resolver ||= ReferenceResolver.new(provider: FootballDataCoUkAdapter::PROVIDER)
    end

    # Error text must never carry SQL, driver internals or a stack trace. Rails'
    # own validation messages are already operator-facing; driver text is not.
    def safe_message(message)
      text = message.to_s
      return 'could not be imported' if text.match?(/PG::|ActiveRecord::|SQLSTATE|stack/i)

      text
    end
  end
end
