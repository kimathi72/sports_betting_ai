require 'net/http'
require 'json'
require 'time'

module Predictions
  # Requests and persists a prediction for ONE market.
  #
  # MARKETS ARE INDEPENDENT. Each call targets a single market, so a failure for
  # btts cannot corrupt a 1x2 prediction already stored. Double chance is derived
  # from the stored 1X2 and never sent to the model.
  #
  # Feature ownership: see Predictions::FeatureBuilder — it is a documented
  # temporary bridge until the ML service exposes a history-based endpoint.
  #
  # A response is validated before anything is written: the market must match,
  # every canonical outcome key must be present, each probability must be in
  # [0,1], and the distribution must sum to 1. Rails never stores a fabricated
  # fallback.
  class MarketPredictor
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 20
    SUM_TOLERANCE = 0.00002

    Result = Struct.new(:prediction, :message, :transient, keyword_init: true) do
      def success?
        message.nil?
      end

      def failure?
        !success?
      end

      def transient?
        transient == true
      end
    end

    def initialize(service_url: ENV.fetch('ML_SERVICE_URL', '').to_s)
      @service_url = service_url.to_s.strip
    end

    attr_reader :service_url

    def call(match, market:)
      return Result.new(message: "unsupported market #{market.inspect}") unless Prediction::MARKETS.include?(market)
      return Result.new(message: 'a completed match already has a result; predicting it would be hindsight') if match.status == 'completed'

      return derive_double_chance(match) if market == 'double_chance'
      return Result.new(message: 'no ML service URL is configured (set ML_SERVICE_URL)') if service_url.empty?

      history = Predictions::MatchHistory.for(match)
      features = Predictions::FeatureBuilder.call(match, history)

      response = post(market, features)
      return Result.new(message: response[:error], transient: response[:transient]) if response[:error]

      store(match, market, response[:body], history)
    end

    private

    # Double chance is a projection of the 1X2 distribution, not a separate model.
    #
    # If this match has no stored 1X2 yet, the 1X2 market is fetched from the ML
    # service first. Without that, a client asking for double chance would get
    # "unsupported" purely because of request ordering — double chance would work
    # only after a separate call it has no reason to know about. Deriving from the
    # freshly stored 1X2 keeps the projection single-sourced: there is still
    # exactly one model producing H/D/A, and nothing is trained for this market.
    def derive_double_chance(match)
      reference = Prediction.current.for_market('1x2').find_by(match_id: match.id)
      reference ||= ensure_1x2(match)

      if reference.nil? || reference.is_a?(Result)
        detail = reference.message if reference.is_a?(Result)
        return Result.new(
          message: detail || 'double chance requires a stored 1x2 prediction for this match',
          transient: reference.is_a?(Result) && reference.transient?
        )
      end

      record = Prediction.new(
        match: match,
        market: 'double_chance',
        model_version: reference.model_version,
        home_probability: 0, draw_probability: 0, away_probability: 1,
        outcomes: reference.double_chance,
        generated_at: Time.current,
        model_metadata: { 'derived_from' => '1x2', 'source_prediction_id' => reference.id }
      )

      return Result.new(message: persistence_error(record)) unless record.save

      Result.new(prediction: record)
    end

    # Fetch and store the 1X2 prediction this match needs, or return the reason.
    # Returns a Prediction on success and a Result (carrying the error) otherwise;
    # nil only when there is no ML service URL to call.
    def ensure_1x2(match)
      return nil if service_url.empty?

      result = Predictions::MarketPredictor.new(service_url: service_url)
                                       .call(match, market: '1x2')
      return result.prediction if result.success?

      result
    end

    def post(market, features)
      uri = URI.join("#{service_url.chomp('/')}/", "predict/#{market}")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['Accept'] = 'application/json'
      # The market travels in the URL path only. The request schema sets
      # `extra="forbid"`, so including `market` in the body is a 422 — verified
      # against ml/app/main.py.
      request.body = JSON.generate(features)

      response = http.start { |connection| connection.request(request) }

      unless response.code.to_i == 200
        return { error: "the ML service returned HTTP #{response.code}", transient: true }
      end

      { body: JSON.parse(response.body.to_s) }
    rescue Net::OpenTimeout, Net::ReadTimeout
      { error: 'the ML service timed out', transient: true }
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError, IOError
      { error: 'the ML service is unreachable', transient: true }
    rescue JSON::ParserError
      { error: 'the ML service returned a response that is not JSON' }
    end

    def store(match, market, body, history)
      outcomes = normalize_outcomes(market, body['probabilities'])
      return Result.new(message: outcomes[:error]) if outcomes[:error]

      version = body['model_version'].to_s
      return Result.new(message: 'the ML response did not include a model_version') if version.strip.empty?

      # 1X2 keeps the legacy column triple in step so existing endpoints and
      # consumers keep working unchanged.
      legacy = market == '1x2' ? outcomes[:distribution] : { 'H' => 0.0, 'D' => 0.0, 'A' => 1.0 }

      record = Prediction.new(
        match: match,
        market: market,
        model_version: version,
        home_probability: legacy.fetch('H', 0.0),
        draw_probability: legacy.fetch('D', 0.0),
        away_probability: legacy.fetch('A', 1.0),
        outcomes: outcomes[:distribution],
        generated_at: parse_time(body['predicted_at']) || Time.current,
        features: { 'history_size' => history.length },
        model_metadata: { 'service_url' => service_url }
      )

      return Result.new(message: persistence_error(record)) unless record.save

      Result.new(prediction: record)
    end

    # Maps a provider key onto the market's canonical spelling, ignoring case.
    # Unknown keys are passed through unchanged so the caller's "unexpected
    # outcome" check still reports them rather than silently dropping them.
    def canonical_key(market, key)
      expected = Prediction::MARKET_OUTCOMES.fetch(market)
      match = expected.find { |candidate| candidate.casecmp?(key.to_s) }
      match || key.to_s
    end

    # Validates the returned distribution against the market's canonical keys.
    def normalize_outcomes(market, raw)
      expected = Prediction::MARKET_OUTCOMES.fetch(market)

      unless raw.is_a?(Hash)
        return { error: 'the ML response did not include probabilities' }
      end

      # 1X2 uses upper-case "H"/"D"/"A" and must NOT be down-cased. Every other
      # market is matched case-insensitively, because the ML service emits
      # "Over"/"Under", "Yes"/"No" and "1X"/"X2" while Rails stores canonical
      # lower case. `expected` is the canonical spelling we store.
      supplied = if market == '1x2'
                   raw.transform_keys(&:to_s)
                 else
                   raw.to_h { |key, value| [canonical_key(market, key), value] }
                 end
      missing = expected - supplied.keys
      extra = supplied.keys - expected
      return { error: "the ML response is missing #{missing.join(', ')}" } if missing.any?
      return { error: "the ML response has unexpected outcomes #{extra.join(', ')}" } if extra.any?

      values = supplied.transform_values { |v| v.is_a?(Numeric) ? v.to_f.round(5) : nil }
      return { error: 'the ML response contained a non-numeric probability' } if values.value?(nil)

      unless values.values.all? { |v| v >= 0.0 && v <= 1.0 }
        return { error: 'the ML response contained a probability outside 0..1' }
      end

      # Double chance outcomes overlap by construction (1X and X2 both include the
      # draw), so they sum to 2. Every other market is a real distribution.
      unless market == 'double_chance'
        total = values.values.sum
        if (total - 1.0).abs > SUM_TOLERANCE
          return { error: "the ML response probabilities sum to #{total.round(5)}, not 1" }
        end
      end

      { distribution: values }
    end

    def persistence_error(record)
      "the prediction could not be stored: #{record.errors.full_messages.to_sentence}"
    end

    def parse_time(value)
      return nil if value.to_s.strip.empty?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
