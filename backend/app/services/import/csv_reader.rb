require 'csv'

module Import
  # The lowest layer of the import pipeline: read a CSV file and hand back raw
  # rows keyed by the file's own header line.
  #
  # It knows nothing about football. Its whole job is to guarantee that the file
  # exists, is parseable, and carries whatever columns the caller declares it
  # needs. That keeps "the shape of the file" separate from "what the columns
  # mean", which is the adapter's concern. Swapping to a different provider file
  # only changes the adapter, not this class.
  #
  # FAILURE MODES are deliberately distinct types, because an operator's next
  # action differs for each:
  #
  #   FileNotFound   — the path does not exist (or is not a readable file)
  #   EmptyFile      — the file exists but carries no content
  #   MissingHeaders — the header line lacks required columns
  #   MalformedCsv   — CSV syntax could not be parsed
  #
  # Malformed syntax is NOT reported as missing headers: telling an operator to
  # fix their column selection when the real problem is an unterminated quote
  # wastes their time. Unrelated IO failures are likewise not relabelled.
  class CsvReader
    # Raised when the requested file is absent. Distinct from the generic
    # Errno::ENOENT so callers can rescue a typed, provider-agnostic error.
    class FileNotFound < StandardError; end

    # Raised when the file exists but is empty (zero bytes, or only whitespace).
    class EmptyFile < StandardError; end

    # Raised when the header line does not contain every required column. The
    # message names the missing columns so an operator can fix the export.
    class MissingHeaders < StandardError; end

    # Raised when the text is not valid CSV (unterminated quotes, bad escapes).
    class MalformedCsv < StandardError; end

    # The BOM some exports (including spreadsheet and Windows tooling) prepend to
    # the first header. Left in place it turns "Div" into "\uFEFFDiv", so every
    # required-column check fails for a perfectly good file.
    UTF8_BOM = "\xEF\xBB\xBF".b.freeze

    # Reads `path` and returns an array of hashes. Each hash maps the literal
    # header text to the raw cell string. No type coercion happens here — the
    # adapter owns interpretation.
    #
    # `required:` is an optional list of header names that must be present; a
    # mismatch raises MissingHeaders before any row is returned.
    def self.read(path, required: [])
      new(path, required: required).read
    end

    def initialize(path, required: [])
      @path = path.to_s
      @required = Array(required)
    end

    def read
      raise FileNotFound, "no such file: #{@path}" unless File.file?(@path)

      text = decode(File.binread(@path))
      raise EmptyFile, "file is empty: #{@path}" if text.strip.empty?

      table = parse(text)
      validate_headers!(table.headers)

      # A trailing newline or a stray blank separator line yields a row whose
      # cells are all nil. Such rows carry no data and are dropped here so the
      # adapter never has to defend against them.
      table.map { |row| row.to_h }
           .reject { |row| row.values.all? { |value| value.nil? || value.to_s.strip.empty? } }
    end

    private

    # Reads bytes, strips a UTF-8 BOM, and forces UTF-8. Invalid byte sequences
    # are replaced rather than raising: a single bad character in an ancillary
    # column should not make an otherwise usable file unreadable.
    def decode(bytes)
      bytes = bytes.byteslice(UTF8_BOM.bytesize..) || '' if bytes.start_with?(UTF8_BOM)

      text = bytes.dup.force_encoding(Encoding::UTF_8)
      text = text.scrub('') unless text.valid_encoding?
      text
    end

    # Only CSV syntax errors are translated; nothing else is caught here, so an
    # unrelated IO failure keeps its own class instead of masquerading as data.
    def parse(text)
      CSV.parse(text, headers: true)
    rescue CSV::MalformedCSVError => e
      raise MalformedCsv, "malformed CSV in #{@path}: #{e.message}"
    end

    def validate_headers!(headers)
      present = Array(headers).compact
      missing = @required - present
      return if missing.empty?

      # Report only the genuinely absent columns. `@required` may legitimately
      # list a column that is present in the file, and naming it here would be
      # misleading to an operator debugging the export. The header text is
      # deliberately omitted from the message: echoing arbitrary file content
      # into an error is noise at best, and this error may surface in logs.
      absent = @required.reject { |column| present.include?(column) }

      raise MissingHeaders,
            "missing required column(s) #{absent.join(', ')} in #{@path}"
    end
  end
end
