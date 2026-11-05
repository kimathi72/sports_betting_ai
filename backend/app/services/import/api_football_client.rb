require "net/http"
require "json"

module Import
  # HTTP client for API-Football (api-sports.io).
  #
  # The ONLY class that knows the provider's transport: its base URL, its
  # `x-apisports-key` authentication header and its error envelope. Everything
  # above it (the adapter, the synchronizer) deals in hashes.
  #
  # WHY STDLIB Net::HTTP
  # --------------------
  # The project already uses Net::HTTP for its other outbound calls and has no
  # HTTP gem. Adding Faraday here would be a second HTTP stack for one endpoint.
  #
  # THE SECRET
  # ----------
  # The key is read from ENV on each request and never assigned to an instance
  # variable or constant, so it cannot appear in `inspect`, a log line or a
  # crash dump. Errors carry the endpoint and the provider's message only.
  #
  # ERROR CLASSIFICATION MATTERS MORE HERE THAN USUAL: the account this project
  # uses is rate-limited to 100 requests per day. A pointless retry is not free,
  # so permanent failures are separated from transient ones and only the latter
  # are ever worth repeating.
  class ApiFootballClient
    BASE_URL_ENV = "API_FOOTBALL_BASE_URL".freeze
    API_KEY_ENV = "API_FOOTBALL_API_KEY".freeze

    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 25

    # Retried: the provider or the network may recover.
    class TransientError < StandardError; end

    # Not retried: credentials, plan or request are wrong.
    class AuthenticationError < StandardError; end
    class ConfigurationError < StandardError; end
    class InvalidContentError < StandardError; end

    class RateLimitError < StandardError
      attr_reader :retry_after_seconds

      def initialize(message, retry_after_seconds: nil)
        super(message)
        @retry_after_seconds = retry_after_seconds
      end
    end

    # An HTTP 200 whose body reports an API-level error (plan restriction, bad
    # parameter). This is the failure mode that would otherwise look like a
    # successful empty import.
    class ApiError < StandardError; end

    Result = Struct.new(:records, :quota_remaining, :quota_limit, :results_count,
                        keyword_init: true)

    def get(path, query: {})
      base_url = fetch_base_url
      uri = build_uri(base_url, path, query)
      response = perform(uri)

      handle_status(response, path)
      parse(response, path)
    end

    # Deliberately omits the key: `inspect` is the usual way a secret reaches a
    # log line by accident.
    def inspect
      "#<#{self.class.name}>"
    end

    private

    def fetch_base_url
      base_url = ENV[BASE_URL_ENV].to_s.strip
      api_key = ENV[API_KEY_ENV].to_s.strip

      if base_url.empty?
        raise ConfigurationError, "#{BASE_URL_ENV} is not configured"
      end
      if api_key.empty?
        raise ConfigurationError, "#{API_KEY_ENV} is not configured"
      end
      # Accept a bare host as well as a full URL.
      #
      # The configured value is a host ("v3.football.api-sports.io"), which is
      # the form the provider documents. Requiring a scheme forced the caller to
      # know whether to add one, and a wrong guess surfaced as an opaque
      # configuration error instead of a working client. A missing scheme is
      # normalised to https; an explicit scheme is always honoured.
      normalized = base_url.include?("://") ? base_url : "https://#{base_url}"
      parsed = begin
        URI.parse(normalized)
      rescue URI::InvalidURIError
        nil
      end
      raise ConfigurationError, "#{BASE_URL_ENV} is not a valid URL" if parsed.nil? || parsed.host.blank?

      normalized.chomp("/")
    end

    def build_uri(base_url, path, query)
      uri = URI.join("#{base_url}/", path.sub(%r{\A/}, ""))
      if query.present?
        uri.query = URI.encode_www_form(query.compact)
      end
      uri
    end

    def perform(uri)
      request = Net::HTTP::Get.new(uri)
      # Read at request time, never stored on the instance.
      request["x-apisports-key"] = ENV[API_KEY_ENV]
      request["Accept"] = "application/json"

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      http.start { |connection| connection.request(request) }
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TransientError, "API-Football request timed out (#{e.class})"
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
      raise TransientError, "API-Football connection failed (#{e.class})"
    end

    def handle_status(response, path)
      status = response.code.to_i

      case status
      when 200..299
        nil
      when 401, 403
        raise AuthenticationError,
              "API-Football rejected the credentials for #{path} (HTTP #{status})"
      when 429
        retry_after = response["retry-after"].to_i
        raise RateLimitError.new(
          "API-Football rate limit reached for #{path}",
          retry_after_seconds: retry_after.positive? ? retry_after : nil,
        )
      when 408, 500..599
        raise TransientError, "API-Football returned HTTP #{status} for #{path}"
      else
        raise InvalidContentError, "API-Football returned HTTP #{status} for #{path}"
      end
    end

    def parse(response, path)
      body = JSON.parse(response.body.to_s)
      unless body.is_a?(Hash) && body.key?("response")
        raise InvalidContentError, "API-Football response for #{path} has no 'response' key"
      end

      # A 200 can still be a failure. The provider puts plan and parameter
      # restrictions here with an empty `response`.
      errors = body["errors"]
      if errors.is_a?(Hash) && errors.any?
        raise ApiError, "API-Football error for #{path}: #{errors.values.join('; ')}"
      end
      if errors.is_a?(Array) && errors.any?
        raise ApiError, "API-Football error for #{path}: #{errors.join('; ')}"
      end

      records = body["response"]
      # /status returns an object in `response`; collection endpoints return a
      # list. Wrapping the object avoids a second client for one boolean.
      records = [records] if records.is_a?(Hash)
      unless records.is_a?(Array)
        raise InvalidContentError, "API-Football response for #{path} is not a list or object"
      end

      Result.new(
        records: records,
        quota_remaining: response["x-ratelimit-requests-remaining"]&.to_i,
        quota_limit: response["x-ratelimit-requests-limit"]&.to_i,
        results_count: body["results"]&.to_i
      )
    rescue JSON::ParserError
      raise InvalidContentError, "API-Football returned malformed JSON for #{path}"
    end
  end
end
