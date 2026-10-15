module Import
  # The outcome of parsing one source row: either a normalized `MatchRow` plus its
  # position in the file, or a human-readable error for that row.
  #
  # A row failure is *data*, not an exception, so the caller can collect every bad
  # row in a file and report them together rather than stopping at the first one.
  RowResult = Struct.new(:index, :row, :error, keyword_init: true) do
    def success?
      error.nil?
    end

    # Errors are reported as "row N: reason". `index` is zero-based internally,
    # so it is rendered one-based to match how a spreadsheet numbers rows.
    def error_message
      return nil if success?

      "row #{index + 1}: #{error}"
    end
  end
end
