require 'net/http'
require 'json'

module Import
  # HTTP client for ESPN's public soccer scoreboard.
  #
  # NO CREDENTIALS. Unlike API-Football this endpoint is open, so there is no key
  # to protect — and therefore nothing in this class that can leak one. It is a
  # separate client rather than a mode on ApiFootballClient because the two APIs
  # share no envelope: ESPN returns a bare object with an `events` array, while
  # API-Football wraps everything in `response` + `errors`.
  #
  # ESPN is used to fill the gap API-Football's free tier leaves: the CURRENT
  # season, which the free plan cannot serve.
  class EspnClient
    BASE_URL = 'https://site.api.espn.com/apis/site/v2/sports/soccer'.freeze
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 20

    # ESPN sends a compressed body; Net::HTTP will not decompress automatically.
    COMPRESSED_HEADERS = ['gzip', 'deflate'].freeze

    class TransientError < StandardError; end
    class InvalidContentError < StandardError; end
    class WindowTooLargeError < ArgumentError; end

    # `days` maps each requested YYYYMMDD to how many events it returned. It is
    # the difference between "the league played nothing on the 4th" and "nobody
    # ever asked about the 4th", which is the distinction the last backfill lost.
    Result = Struct.new(:events, :provider_ok, :days, keyword_init: true)

    # A single season window is at most one year. Longer than that is not a
    # season refresh; it would be hundreds of requests against a free endpoint.
    MAX_WINDOW_DAYS = 370

    # league: ESPN's league slug, e.g. "eng.1".
    # date: optional YYYYMMDD; nil means "today"/live board.
    def scoreboard(league:, date: nil)
      uri = build_uri(league, date)
      response = perform(uri)

      case response.code.to_i
      when 200..299 then nil
      when 408, 500..599 then raise TransientError, "ESPN returned HTTP #{response.code} for #{league}"
      else raise InvalidContentError, "ESPN returned HTTP #{response.code} for #{league}"
      end

      body = JSON.parse(decompress(response).to_s)
      unless body.is_a?(Hash) && body.key?('events')
        raise InvalidContentError, "ESPN response for #{league} has no 'events' key"
      end

      Result.new(events: Array(body['events']), provider_ok: true)
    rescue JSON::ParserError
      raise InvalidContentError, "ESPN returned malformed JSON for #{league}"
    end

    # ONE event, by id.
    #
    # WHY THIS EXISTS
    # ---------------
    # `scoreboard` answers "what happened in this league on this day" — a whole
    # day's payload. Checking a single finished fixture that way costs the same
    # request but returns every other match on the day, and a caller that then
    # iterates them can touch fixtures it was never asked about. This method asks
    # about exactly one event.
    #
    # The summary endpoint returns the event under `header.competitions[0]`, which
    # is the same shape `EspnAdapter#normalize_fixture` already parses, so the
    # adapter and the reconciler are reused unchanged. The payload is returned as
    # a single event hash, not wrapped in a Result: there is exactly one event, and
    # a caller that had to unwrap an array of one would be tempted to iterate.
    #
    # A 404 is a PERMANENT answer (the event does not exist at this league), not a
    # transient one: retrying it forever is a retry storm against a free endpoint.
    def event(league:, event_id:)
      raise ArgumentError, "event_id is required" if event_id.to_s.strip.empty?

      uri = URI.parse("#{BASE_URL}/#{league}/summary?event=#{URI.encode_www_form_component(event_id.to_s)}")
      response = perform(uri)

      case response.code.to_i
      when 200..299 then nil
      when 404 then raise InvalidContentError, "ESPN has no event #{event_id} in #{league}"
      when 408, 500..599 then raise TransientError, "ESPN returned HTTP #{response.code} for event #{event_id}"
      else raise InvalidContentError, "ESPN returned HTTP #{response.code} for event #{event_id}"
      end

      body = JSON.parse(decompress(response).to_s)
      competition = body.dig("header", "competitions", 0)
      unless competition.is_a?(Hash)
        raise InvalidContentError, "ESPN event #{event_id} has no header.competitions[0]"
      end

      # RETURN THE SCOREBOARD EVENT SHAPE, NOT THE BARE COMPETITION.
      #
      # `EspnAdapter#normalize_fixture` reads `payload['competitions']`, because
      # that is how a scoreboard event is shaped. The summary endpoint nests the
      # competition under `header`, so returning it directly produced a payload
      # with no `competitions` key and the adapter rejected every event as
      # "unusable payload" — which is exactly what the first live run recorded.
      #
      # The summary payload also does not repeat the event id inside the
      # competition, so it is attached here; without it the adapter would produce
      # a row with no provider key and the reconciler could not match it.
      {
        "id" => body.dig("header", "id") || event_id.to_s,
        "date" => competition["date"],
        "season" => body.dig("header", "season") || body["season"],
        "competitions" => [competition]
      }
    rescue JSON::ParserError
      raise InvalidContentError, "ESPN returned malformed JSON for event #{event_id}"
    end

    # League team rosters. Not gzip-encoded by ESPN, unlike the scoreboard, so it
    # goes through the same `perform` but skips decompression.
    def teams(league:)
      uri = URI.parse("#{BASE_URL}/#{league}/teams")
      response = perform(uri)
      unless (200..299).cover?(response.code.to_i)
        raise InvalidContentError, "ESPN returned HTTP #{response.code} for #{league}/teams"
      end

      body = JSON.parse(decompress(response).to_s)
      Array(body.dig("sports", 0, "leagues", 0, "teams"))
    rescue JSON::ParserError
      raise InvalidContentError, "ESPN returned malformed JSON for #{league}/teams"
    end

    # Every event for every day in the window, merged into one result.
    #
    # WHY DAY BY DAY
    # --------------
    # ESPN accepts `dates=YYYYMMDD` for a single day. Every range form was tried
    # against the live endpoint and returned zero events, so a range cannot be
    # trusted: it fails silently, looking exactly like "no fixtures". Walking the
    # days costs one request per day and, crucially, lets the caller see which
    # days were actually requested.
    #
    # A day that returns no events is a valid answer, not an error. Only a
    # provider failure raises, and it raises for the whole window rather than
    # returning a partial result silently — a half-fetched window that reports
    # success is how a gap becomes permanent.
    #
    # Duplicates are impossible across days (an event has one date), but the
    # merge keeps first-seen order so the caller's counts are stable.
    #
    # The keywords are `from_date`/`to_date`, not `from`/`to`. Inside a method body
    # a parameter named `to` shadows Kernel#to, so `to_date(to)` becomes a call to
    # Kernel#to (arity 1) rather than to the conversion helper — a real bug this
    # suite caught. Naming them apart removes the trap instead of working around it.
    def scoreboard_dates(league:, from_date:, to_date:)
      first_day = coerce_date(from_date)
      last_day = coerce_date(to_date)
      return Result.new(events: [], provider_ok: true, days: {}) if last_day < first_day

      span = (last_day - first_day).to_i + 1
      if span > MAX_WINDOW_DAYS
        raise WindowTooLargeError,
              "date window of #{span} days exceeds the #{MAX_WINDOW_DAYS}-day maximum"
      end

      days = {}
      events = []
      (first_day..last_day).each do |day|
        key = day.strftime('%Y%m%d')
        result = scoreboard(league: league, date: key)
        days[key] = result.events.size
        events.concat(result.events)
      end

      Result.new(events: events, provider_ok: true, days: days)
    end

    private

    def coerce_date(value)
      return value if value.is_a?(Date)

      Date.parse(value.to_s)
    rescue Date::Error, TypeError
      raise ArgumentError, "not a date: #{value.inspect}"
    end

    def build_uri(league, date)
      url = "#{BASE_URL}/#{league}/scoreboard"
      url += "?dates=#{date}" if date
      URI.parse(url)
    end

    def perform(uri)
      request = Net::HTTP::Get.new(uri)
      request['Accept'] = 'application/json'
      request['Accept-Encoding'] = COMPRESSED_HEADERS.join(', ')
      request['User-Agent'] = 'sports-betting-ai/1.0'

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      http.start { |connection| connection.request(request) }
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TransientError, "ESPN request timed out (#{e.class})"
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
      raise TransientError, "ESPN connection failed (#{e.class})"
    end

    # Net::HTTP returns the raw compressed bytes; `[]` on the response reports
    # the Content-Encoding. Inflating here keeps callers dealing with JSON.
    def decompress(response)
      body = response.body.to_s
      encoding = response['content-encoding'].to_s.downcase

      case encoding
      when 'gzip'
        Zlib::GzipReader.new(StringIO.new(body)).read
      when 'deflate'
        Zlib::Inflate.inflate(body)
      else
        body
      end
    rescue Zlib::Error
      # Already-decoded or mislabelled; try the body as-is rather than failing.
      body
    end
  end
end
