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
  class CsvReader
    # Raised when the requested file is absent. Distinct from the generic
    # Errno::ENOENT so callers can rescue a typed, provider-agnostic error.
    class FileNotFound < StandardError; end

    # Raised when the header line does not contain every required column. The
    # message names the missing columns so an operator can fix the export.
    class MissingHeaders < StandardError; end

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

      table = CSV.read(@path, headers: true)
      validate_headers!(table.headers)

      # A trailing newline or a stray blank separator line yields a row whose
      # cells are all nil. Such rows carry no data and are dropped here so the
      # adapter never has to defend against them.
      table.map { |row| row.to_h }
           .reject { |row| row.values.all? { |value| value.nil? || value.strip.empty? } }
    rescue CSV::MalformedCSVError => e
      raise MissingHeaders, "malformed CSV in #{@path}: #{e.message}"
    end

    private

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
