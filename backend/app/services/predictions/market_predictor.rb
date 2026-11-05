require 'net/http'
require 'json'
require 'time'

module Predictions
  # Requests and persists a prediction for ONE market.
  #
  # MARKETS ARE INDEPENDENT. Each call targets a single market, so a failure for
  # BTTS cannot corrupt a 1X2 prediction already stored.
  #
  # FEATURES ARE NOT COMPUTED HERE. The request carries the fixture and its
  # history to `POST /predict/from-history/{market}`, and the ML service turns that
  # into the feature vector. An earlier version mirrored the feature formulas in
  # Ruby so it could post a flat vector; that was a second implementation of the
  # same maths, and a divergence there is invisible — the predictions just quietly
  # stop matching the model. `Predictions::MatchHistory` still owns WHICH matches
  # count as history, and the service re-applies the kickoff cutoff independently,
  # so a filtering bug on either side cannot leak a result.
  #
  # DOUBLE CHANCE is derived by the ML service from the same 1X2 distribution, so
  # P(1X) = P(H) + P(D) holds by construction. Rails does not compute it, and does
  # not train or load anything for it.
  #
  # A response is validated before anything is written: the market must match,
  # every canonical outcome key must be present, each probability must be in
  # [0,1], and the distribution must sum to 1. Rails never stores a fabricated
  # fallback, and never invents a confidence when the service has no model.
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

    # `source:` selects WHICH published model answers a history request:
    #   - nil (default)  the service's own default, which is its per-market classifier;
    #   - "goal_model"   the joint scoreline distribution.
    # Rails never sets it in normal operation. It exists so an operator can compare
    # the two sources on the same fixture without redeploying the service, which is
    # how the weaker source was diagnosed. The caller must pass a value the service
    # accepts, or the request fails with a clear 422 rather than silently guessing.
    def initialize(service_url: ENV.fetch('ML_SERVICE_URL', '').to_s, source: nil)
      @service_url = service_url.to_s.strip
      @source = source.presence
    end

    attr_reader :service_url

    def call(match, market:)
      return Result.new(message: "unsupported market #{market.inspect}") unless Prediction::MARKETS.include?(market)
      return Result.new(message: 'a completed match already has a result; predicting it would be hindsight') if match.status == 'completed'
      # A fixture still stored as `scheduled` whose kickoff has passed is the same
      # situation as far as evidence is concerned. The stored status is an
      # ingestion artefact: on 2026-11-04, matches 39662 and 39676 had finished but
      # their results were not yet ingested, so they still read `scheduled` and the
      # pipeline issued predictions hours late. Nothing downstream could save those
      # as evidence (the eligibility gate refused them), but they should not exist.
      # Checked here, in the producer, so the rule holds whichever caller asks.
      if match.kickoff_at.present? && match.kickoff_at <= Time.current
        return Result.new(message: 'this fixture has already kicked off; a prediction now would be hindsight')
      end
      return Result.new(message: 'no ML service URL is configured (set ML_SERVICE_URL)') if service_url.empty?

      history = Predictions::MatchHistory.for(match)
      response = post(market, match, history)
      return Result.new(message: response[:error], transient: response[:transient]) if response[:error]

      store(match, market, response[:body], history)
    end

    private

    def post(market, match, history)
      uri = URI.join("#{service_url.chomp('/')}/", "predict/from-history/#{market}")
      uri.query = URI.encode_www_form(source: @source) if @source

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['Accept'] = 'application/json'
      request.body = JSON.generate(
        'match' => serialize_match(match),
        'history' => history.map { |row| serialize_history(row) }
      )

      response = http.start { |connection| connection.request(request) }

      return classify_failure(response) unless response.code.to_i == 200

      { body: JSON.parse(response.body.to_s) }
    rescue Net::OpenTimeout, Net::ReadTimeout
      { error: 'the ML service timed out', transient: true }
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError, IOError
      { error: 'the ML service is unreachable', transient: true }
    rescue JSON::ParserError
      { error: 'the ML service returned a response that is not JSON' }
    end

    # A 400 means the caller sent something the service refuses (an unsupported
    # market, a malformed fixture). That is not transient, and retrying it forever
    # would hide a real bug. 503 means no model is published for this market: the
    # service is up, so the message says so instead of pretending it is down.
    def classify_failure(response)
      code = response.code.to_i
      detail = extract_detail(response)
      case code
      when 400
        { error: "the ML service rejected the request: #{detail}" }
      when 422
        { error: "the ML request did not match the service schema: #{detail}" }
      when 503
        { error: "no model is available for this market: #{detail}" }
      when 500..599
        { error: "the ML service returned HTTP #{code}", transient: true }
      else
        { error: "the ML service returned HTTP #{code}: #{detail}" }
      end
    end

    def extract_detail(response)
      body = JSON.parse(response.body.to_s)
      detail = body.is_a?(Hash) ? body['detail'] : nil
      detail.is_a?(Array) ? detail.map { |d| d['msg'] || d.to_s }.join('; ') : detail.to_s
    rescue JSON::ParserError
      ''
    end

    def serialize_match(match)
      {
        'id' => match.id,
        'kickoff_at' => match.kickoff_at.utc.iso8601,
        'status' => match.status,
        'home_team_id' => match.home_team_id,
        'away_team_id' => match.away_team_id,
        'home_score' => match.home_score,
        'away_score' => match.away_score,
        'competition_id' => match.competition_id
      }
    end

    # Only the fields the service reads. A history payload should not become a
    # second copy of the matches endpoint.
    def serialize_history(row)
      {
        'id' => row['id'],
        'kickoff_at' => Time.parse(row['kickoff_at'].to_s).utc.iso8601,
        'status' => row['status'],
        'home_team_id' => row['home_team_id'],
        'away_team_id' => row['away_team_id'],
        'home_score' => row['home_score'],
        'away_score' => row['away_score']
      }
    end

    def store(match, market, body, history)
      declared = body['market'].to_s
      return Result.new(message: "the ML response was for market #{declared.inspect}, not #{market.inspect}") \
        if declared.present? && declared != market

      outcomes = normalize_outcomes(market, body['probabilities'])
      return Result.new(message: outcomes[:error]) if outcomes[:error]

      version = body['model_version'].to_s
      return Result.new(message: 'the ML response did not include a model_version') if version.strip.empty?

      # 1X2 keeps the legacy column triple in step so existing endpoints and
      # consumers keep working unchanged. Other markets store their own outcomes
      # and leave the legacy triple at a neutral value.
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
        features: { 'history_size' => history.length, 'feature_version' => body['feature_version'] },
        # Provenance for prospective evaluation. `feature_version` is emitted by the
        # ML service and was previously dropped; the freeze digest identifies the
        # exact artifact generation that issued this probability. When the service
        # does not report a digest it stays null rather than being invented, and the
        # eligibility check will treat the prediction as unattributable.
        model_freeze_digest: body['model_freeze_digest'].presence,
        model_metadata: {
          'service_url' => service_url,
          'endpoint' => "predict/from-history/#{market}",
          'feature_version' => body['feature_version'],
          'model_freeze_digest' => body['model_freeze_digest'].presence
        }.compact
      )

      return Result.new(message: persistence_error(record)) unless record.save

      Result.new(prediction: record)
    end

    # Maps a provider key onto the market's canonical spelling, ignoring case.
    def canonical_key(market, key)
      expected = Prediction::MARKET_OUTCOMES.fetch(market)
      expected.find { |candidate| candidate.casecmp?(key.to_s) } || key.to_s
    end

    def normalize_outcomes(market, raw)
      return normalize_correct_score(raw) if market == 'correct_score'

      expected = Prediction::MARKET_OUTCOMES.fetch(market)

      return { error: 'the ML response did not include probabilities' } unless raw.is_a?(Hash)

      # 1X2 uses upper-case "H"/"D"/"A" and must NOT be down-cased. Every other
      # market is matched case-insensitively, because the ML service emits
      # "Over"/"Under", "Yes"/"No" and "1X"/"X2" while Rails stores canonical
      # lower case.
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
      return { error: 'the ML response contained a probability outside 0..1' } unless values.values.all? { |v| v >= 0.0 && v <= 1.0 }

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

    # Correct score has no fixed outcome list: the service returns the most likely
    # scorelines, already truncated. Rails validates the shape (it reuses the model
    # validation) and stores them unchanged, because re-ranking an unordered hash
    # would destroy the ordering a client uses to pick one line.
    def normalize_correct_score(raw)
      return { error: 'the ML response did not include probabilities' } unless raw.is_a?(Hash)
      return { error: 'the ML response contained no scorelines' } if raw.empty?

      # JSON object order is preserved by Ruby's parser, so the ranking the service
      # chose survives; sorting here would re-rank ties arbitrarily.
      distribution = raw.map { |key, value| [key.to_s, value] }.to_h
      return { error: 'the ML response contained a non-numeric probability' } if distribution.values.any? { |v| !v.is_a?(Numeric) }
      return { error: 'the ML response contained a probability outside 0..1' } unless distribution.values.all? { |v| v >= 0.0 && v <= 1.0 }

      { distribution: distribution.transform_values { |v| v.to_f.round(5) } }
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
