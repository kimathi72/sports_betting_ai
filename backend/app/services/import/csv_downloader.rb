require 'csv'
require 'net/http'
require 'uri'
require 'json'
require 'digest'
require 'fileutils'
require 'time'

module Import
  # Fetches historical football-data.co.uk CSV files into `data/raw/`.
  #
  # This is the only class in the project that touches the network, so it is
  # deliberately narrow and careful:
  #
  #   - the URL is DERIVED from a validated season code and division, never
  #     supplied by a caller, and only ALLOWED_HOST is contacted. Redirects are
  #     followed manually so each hop can be checked against the same rule;
  #   - timeouts are finite, attempts are bounded, and only transient failures
  #     (timeouts, resets, 5xx) are retried;
  #   - content is validated before it is promoted: an HTML error page, an empty
  #     body or a header with no data rows is rejected rather than written;
  #   - older seasons legitimately omit `Time`, so that one column is optional;
  #   - the file is written to a temporary path and atomically renamed, so a
  #     failed download can never leave a half-written CSV behind;
  #   - an existing file is never replaced unless `overwrite:` is explicit;
  #   - provenance (source URL, timestamp, season, division, size, SHA-256) is
  #     recorded beside the file so an import can be reproduced and audited.
  #
  # Nothing here interprets the data. Once a file is on disk, importing it is the
  # importer's job, which keeps provider-specific knowledge in the adapter.
  class CsvDownloader
    # The only hosts this class will contact. The source answers on `www` with a
    # 302 to the apex domain, which serves the actual CSV, so both are official.
    # The list is closed: any other host is refused, including via redirect.
    ALLOWED_HOST = 'www.football-data.co.uk'.freeze
    ALLOWED_HOSTS = [ALLOWED_HOST, 'football-data.co.uk'].freeze

    # The source's path layout: /mmz4281/{YYXX}/{division}.csv
    URL_PATH = '/mmz4281/%<season_code>s/%<division>s.csv'.freeze
    BASE_URL = "https://#{ALLOWED_HOST}".freeze

    # football-data.co.uk identifies a season by a two-year code ("2425").
    SEASON_CODE_PATTERN = /\A\d{4}\z/.freeze
    SEASON_LABEL_PATTERN = /\A(\d{4})\/(\d{2}|\d{4})\z/.freeze

    # A closed list on purpose: an unexpected code would silently fetch a
    # different competition's file.
    #
    # Verified against the live source on 2026-11-01 (every code returned HTTP
    # 200 with a CSV body): E0/E1/E2/E3 are the English tiers, EC/SC0/SC1 are the
    # Conference and the two Scottish tiers, SP/D/I/F/N/B/P/T are Spain, Germany,
    # Italy, France, Netherlands, Belgium, Portugal and Turkey, and G1 is Greece.
    # A competition is added here only after a real request confirmed it, exactly
    # as with the ESPN league slugs.
    SUPPORTED_DIVISIONS = %w[E0 E1 E2 E3 EC SC0 SC1 SP1 SP2 D1 D2 I1 I2 F1 F2 N1 B1 P1 T1 G1].freeze

    # Country and competition name per division. Used only for reporting and for
    # naming a canonical Competition when a division is imported for the first
    # time; the recorded Competition is created by the importer, not here.
    DIVISION_LABELS = {
      'E0' => %w[England Premier\ League],
      'E1' => %w[England Championship],
      'E2' => %w[England League\ One],
      'E3' => %w[England League\ Two],
      'EC' => %w[England Conference],
      'SC0' => %w[Scotland Premiership],
      'SC1' => %w[Scotland Championship],
      'SP1' => %w[Spain La\ Liga],
      'SP2' => %w[Spain Segunda\ Division],
      'D1' => %w[Germany Bundesliga],
      'D2' => %w[Germany 2.\ Bundesliga],
      'I1' => %w[Italy Serie\ A],
      'I2' => %w[Italy Serie\ B],
      'F1' => %w[France Ligue\ 1],
      'F2' => %w[France Ligue\ 2],
      'N1' => %w[Netherlands Eredivisie],
      'B1' => %w[Belgium Pro\ League],
      'P1' => %w[Portugal Primeira\ Liga],
      'T1' => %w[Turkey Super\ Lig],
      'G1' => %w[Greece Super\ League]
    }.freeze

    # Columns a usable file must have. `Time` is NOT here: seasons before
    # 2019/20 do not publish kickoff times, and rejecting those files would make
    # the older history permanently unreachable.
    REQUIRED_COLUMNS = %w[Div Date HomeTeam AwayTeam FTHG FTAG FTR].freeze
    OPTIONAL_COLUMNS = %w[Time].freeze

    # Raw downloads live beside the committed fixtures but are git-ignored
    # (see .gitignore: data/raw/*, with .gitkeep preserved). Inside Docker the
    # repository data directory is mounted at /data; locally it resolves relative
    # to the Rails root.
    DEFAULT_DESTINATION = begin
      # RAW_IMPORT_DIR lets a deployment (or the download task inside Docker,
      # where /data is mounted read-only for the importers) point downloads at a
      # writable location. Otherwise the project's own data/raw is used.
      configured = ENV['RAW_IMPORT_DIR'].to_s
      if configured.strip.empty?
        mounted = '/data/raw'
        File.directory?('/data') ? mounted : Rails.root.join('..', 'data', 'raw').to_s
      else
        configured
      end
    end

    OPEN_TIMEOUT = 15     # seconds
    READ_TIMEOUT = 60     # seconds
    MAX_ATTEMPTS = 3      # total attempts, transient failures only
    BACKOFF_SECONDS = 2   # base delay, multiplied by the attempt number
    MAX_REDIRECTS = 3
    USER_AGENT = 'sports-betting-ai/1.0 (historical football import)'.freeze

    # Bad caller input: a season or division that cannot map to a real file.
    class InvalidInput < ArgumentError; end

    # The request failed permanently and must not be retried (4xx other than the
    # transient ones, or a redirect that leaves the allowed host).
    class Unavailable < StandardError; end

    # Every attempt failed for a reason that might succeed later.
    class TransientError < StandardError; end

    # The response arrived but is not a usable CSV.
    class InvalidContent < StandardError; end

    # Outcome of one season download. `status` is :downloaded or :already_present.
    Result = Struct.new(:season, :season_code, :division, :file_path, :metadata_path,
                        :status, :checksum, :size, :has_time_column, :error, keyword_init: true) do
      def success?
        status == :downloaded
      end

      def downloaded
        success?
      end

      def already_present?
        status == :already_present
      end

      def missing_time_column?
        !has_time_column
      end
    end

    def initialize(destination_dir:, division: 'E0', overwrite: false)
      @destination_dir = destination_dir.to_s
      @division = normalize_division(division)
      @overwrite = overwrite
    end

    attr_reader :destination_dir, :division

    # Downloads every requested season in order. One failure raises rather than
    # being buried in the returned list: a caller asking for three seasons must
    # not have to scan results to notice that one is missing.
    def download(seasons:)
      list = Array(seasons).compact.map(&:to_s)
      raise InvalidInput, 'at least one season is required' if list.empty?

      list.map { |season| download_one(season: season) }
    end

    # Downloads, or reports, a single season.
    def download_one(season:)
      code = season_code(season)
      label = normalize_season(season)
      path = File.join(destination_dir, "#{code}_#{division}.csv")
      metadata_path = "#{path}.metadata.json"

      if File.file?(path) && !@overwrite
        return Result.new(
          season: label, season_code: code, division: division,
          file_path: path, metadata_path: metadata_path, status: :already_present,
          checksum: Digest::SHA256.file(path).hexdigest, size: File.size(path),
          has_time_column: metadata_has_time(metadata_path)
        )
      end

      body = fetch(code)
      has_time = validate_content!(body, season_code: code)

      promote(body, path, metadata_path, season: label, code: code, has_time_column: has_time)
    end

    # The exact URL a season resolves to, without making a request. Exposed so an
    # operator can verify what will be fetched and the specs can assert it.
    def source_url(season:)
      format("#{BASE_URL}#{URL_PATH}", season_code: season_code(season), division: division)
    end

    private

    def normalize_division(value)
      text = value.to_s.strip.upcase
      unless SUPPORTED_DIVISIONS.include?(text)
        raise InvalidInput,
              "unsupported division #{value.inspect}; expected one of #{SUPPORTED_DIVISIONS.join(', ')}"
      end

      text
    end

    # Accepts both the platform label ("2024/25") and the source code ("2425"),
    # returning the source code. Anything else is rejected rather than guessed: a
    # wrong code would silently download a different season's file.
    def season_code(value)
      text = value.to_s.strip

      code = if text.match?(SEASON_CODE_PATTERN)
               text
             elsif (match = text.match(SEASON_LABEL_PATTERN))
               start = match[1]
               finish = match[2].length == 2 ? match[2] : match[2][-2..]
               "#{start[-2..]}#{finish}"
             end

      unless code && plausible_season?(code)
        raise InvalidInput, "unknown season #{value.inspect}; expected a form such as 2024/25 or 2425"
      end

      code
    end

    # A code is plausible when the two years are consecutive and the season has
    # begun. This catches typos such as 2099/30 before a pointless request.
    def plausible_season?(code)
      start = code[0, 2].to_i
      finish = code[2, 2].to_i
      return false unless finish == ((start + 1) % 100)

      year = 2000 + start
      year >= 2000 && year <= Time.now.utc.year
    end

    def normalize_season(value)
      text = value.to_s.strip
      return text unless text.match?(SEASON_CODE_PATTERN)

      start = 2000 + text[0, 2].to_i
      "#{start}/#{text[2, 2]}"
    end

    # Retries only transient failures. A permanent failure propagates at once;
    # exhausting the attempts raises TransientError carrying the last cause, so a
    # caller can tell "try later" from "bad input".
    def fetch(code)
      url = format("#{BASE_URL}#{URL_PATH}", season_code: code, division: division)
      last_error = nil

      1.upto(MAX_ATTEMPTS) do |attempt|
        begin
          return http_get(URI(url), season_code: code)
        rescue TransientError => e
          last_error = e
          sleep(BACKOFF_SECONDS * attempt) if attempt < MAX_ATTEMPTS
        end
      end

      raise TransientError,
            "could not download #{url} after #{MAX_ATTEMPTS} attempts: #{last_error.message}"
    end

    def http_get(uri, season_code:, redirects_left: MAX_REDIRECTS)
      assert_allowed_uri!(uri)
      response = perform_request(uri)

      case response.code.to_i
      when 200
        body = response.body.to_s
        # An empty 200 is not a network fault: retrying would just fetch the same
        # empty body. It is unusable content, and the caller is told so at once.
        raise InvalidContent, 'the source returned an empty response' if body.strip.empty?

        body
      when 301, 302, 303, 307, 308
        raise InvalidContent, 'too many redirects' if redirects_left.zero?

        location = response['location'].to_s
        raise InvalidContent, 'redirect without a Location header' if location.empty?

        next_uri = URI.join(uri, location)
        http_get(next_uri, season_code: season_code, redirects_left: redirects_left - 1)
      when 408, 425, 429, 500, 502, 503, 504
        raise TransientError, "temporary HTTP #{response.code}"
      when 404, 410
        raise Unavailable,
              "season #{normalize_season(season_code)} is not available (HTTP #{response.code})"
      else
        raise Unavailable, "the source returned HTTP #{response.code}"
      end
    end

    def perform_request(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.write_timeout = OPEN_TIMEOUT if http.respond_to?(:write_timeout=)

      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = USER_AGENT
      request['Accept'] = 'text/csv,*/*'

      http.start { |connection| connection.request(request) }
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout => e
      raise TransientError, "timed out (#{e.class})"
    rescue Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EPIPE, Errno::ETIMEDOUT,
           SocketError, IOError, OpenSSL::SSL::SSLError => e
      raise TransientError, "connection failed (#{e.class})"
    end

    # Only the official hosts over HTTPS — checked on every hop, so a redirect
    # cannot move the request to another origin.
    def assert_allowed_uri!(uri)
      return if uri.is_a?(URI::HTTPS) && ALLOWED_HOSTS.include?(uri.host)

      raise InvalidContent, "refusing to follow a redirect to #{uri.host || 'an unknown host'}"
    end

    # Validation runs on the downloaded text, before anything reaches disk.
    # Returns whether the file carries a Time column.
    #
    # The bytes are decoded as UTF-8 with invalid sequences replaced. The source
    # has published Windows-1252/odd-byte files over the years; comparing raw
    # ASCII-8BIT bytes against UTF-8 literals raises Encoding::CompatibilityError,
    # which is exactly the failure this guards against. The file is stored
    # byte-for-byte as received; only the checks read the decoded copy.
    def validate_content!(body, season_code:)
      text = body.to_s.dup.force_encoding(Encoding::UTF_8)
      text = text.scrub('') unless text.valid_encoding?

      head = text.lstrip[0, 512].to_s
      if head.match?(/\A<(!doctype\s+html|html|\?xml)/i) || head.start_with?('<')
        raise InvalidContent, "the response for #{season_code} is an HTML page, not a CSV"
      end

      table = begin
        CSV.parse(text, headers: true)
      rescue CSV::MalformedCSVError => e
        raise InvalidContent, "the downloaded CSV is malformed: #{e.message}"
      end

      headers = Array(table.headers).map { |header| header.to_s.strip.delete_prefix("\uFEFF") }
      missing = REQUIRED_COLUMNS - headers
      unless missing.empty?
        raise InvalidContent, "the downloaded CSV is missing required column(s) #{missing.join(', ')}"
      end

      usable = table.reject do |row|
        row.to_h.values.all? { |value| value.nil? || value.to_s.strip.empty? }
      end
      raise InvalidContent, 'the downloaded CSV contains no data rows' if usable.empty?

      headers.include?('Time')
    end

    # Writes beside the destination and renames into place. A rename within one
    # filesystem is atomic, so no reader observes a partial file, and a failure
    # leaves neither the file nor its temporary sibling behind.
    def promote(body, path, metadata_path, season:, code:, has_time_column:)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp-#{Process.pid}"
      meta_tmp = "#{metadata_path}.tmp-#{Process.pid}"

      metadata = {
        'source_url' => format("#{BASE_URL}#{URL_PATH}", season_code: code, division: division),
        'retrieved_at' => Time.now.utc.iso8601,
        'season' => season,
        'season_code' => code,
        'division' => division,
        'provider' => 'football_data',
        'bytes' => body.bytesize,
        'sha256' => Digest::SHA256.hexdigest(body),
        'has_time_column' => has_time_column
      }

      File.binwrite(tmp, body)
      File.write(meta_tmp, JSON.pretty_generate(metadata) + "\n")

      File.rename(tmp, path)
      File.rename(meta_tmp, metadata_path)

      Result.new(
        season: season, season_code: code, division: division,
        file_path: path, metadata_path: metadata_path, status: :downloaded,
        checksum: metadata['sha256'], size: metadata['bytes'],
        has_time_column: has_time_column
      )
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
      File.delete(meta_tmp) if meta_tmp && File.exist?(meta_tmp)
    end

    def metadata_has_time(path)
      JSON.parse(File.read(path))['has_time_column']
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end
  end
end
