require 'net/http'
require 'json'
require 'time'

module Predictions
  # Asks the FastAPI ML service for a 1X2 prediction for one fixture, then stores
  # it.
  #
  # SEPARATION OF CONCERNS. Rails owns the data and the record; the ML service
  # owns the model and the feature vector. This class does not compute features —
  # `Predictions::MatchHistory` supplies time-safe history and Kilo's
  # `compute_match_features` turns it into the 17 inputs. Duplicating that maths
  # here would give the project two implementations that silently disagree.
  #
  # TRAINING IS NOT HERE. This class never trains, retrains or tunes a model. A
  # prediction request is a read-only call to an already-loaded model; model
  # lifecycle is the ML service's job.
  #
  # The response is validated before anything is written: three probabilities that
  # are each in [0,1] and sum to 1, plus a model version. A malformed response is
  # a failure, never a half-stored prediction.
  class Predictor
    OPEN_TIMEOUT = 5   # seconds
    READ_TIMEOUT = 15  # seconds

    # Outcomes as the ML service names them.
    OUTCOME_KEYS = { 'H' => :home_probability, 'D' => :draw_probability, 'A' => :away_probability }.freeze

    # `error` is a method name RSpec's own example context also defines, so the
    # member is named `message` to keep call sites unambiguous.
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

    def call(match)
      return Result.new(message: 'no ML service URL is configured (set ML_SERVICE_URL)') if service_url.empty?
      return Result.new(message: 'a completed match already has a result; predicting it would be hindsight') if completed?(match)

      payload = build_payload(match)
      response = post_json(payload)
      return Result.new(message: response[:error], transient: response[:transient]) if response[:error]

      store(match, response[:body], payload)
    end

    private

    def completed?(match)
      match.status == 'completed'
    end

    def build_payload(match)
      {
        'match' => serialize_match(match),
        'history' => Predictions::MatchHistory.for(match),
        'competition' => match.competition.name,
        'season' => match.season.name
      }
    end

    def serialize_match(match)
      {
        'id' => match.id,
        'kickoff_at' => match.kickoff_at.utc.iso8601,
        'status' => match.status,
        'home_team_id' => match.home_team_id,
        'away_team_id' => match.away_team_id,
        'home_team_name' => match.home_team.name,
        'away_team_name' => match.away_team.name,
        'home_score' => match.home_score,
        'away_score' => match.away_score
      }
    end

    def post_json(payload)
      uri = URI.join("#{service_url.chomp('/')}/", 'predict')

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['Accept'] = 'application/json'
      request.body = JSON.generate(payload)

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

    def store(match, body, payload)
      probabilities = extract_probabilities(body)
      return Result.new(message: probabilities[:error]) if probabilities[:error]

      version = body['model_version'].to_s
      return Result.new(message: 'the ML response did not include a model_version') if version.strip.empty?

      prediction = Prediction.new(
        match: match,
        model_version: version,
        home_probability: probabilities[:home],
        draw_probability: probabilities[:draw],
        away_probability: probabilities[:away],
        generated_at: parse_time(body['predicted_at']) || Time.current,
        # Kept so a stored prediction can be reproduced and audited.
        features: { 'history_size' => payload['history'].length },
        model_metadata: { 'service_url' => service_url }
      )

      unless prediction.save
        return Result.new(message: "the prediction could not be stored: #{prediction.errors.full_messages.to_sentence}")
      end

      Result.new(prediction: prediction)
    end

    def extract_probabilities(body)
      raw = body['probabilities']
      return { error: 'the ML response did not include probabilities' } unless raw.is_a?(Hash)

      # Keyed by the ML service's own names: "H", "D", "A".
      values = OUTCOME_KEYS.to_h { |source, target| [target, raw[source]] }
      missing = OUTCOME_KEYS.keys.reject { |key| raw[key].is_a?(Numeric) }
      unless missing.empty?
        return { error: "the ML response is missing probability for #{missing.join(', ')}" }
      end

      # Rounded to the stored precision so the database's sum check is not
      # tripped by a float artefact from the JSON decoder.
      rounded = values.transform_values { |value| value.to_f.round(5) }
      total = rounded.values.sum
      unless (total - 1.0).abs <= 0.00002
        return { error: "the ML response probabilities sum to #{total.round(5)}, not 1" }
      end

      { home: rounded[:home_probability], draw: rounded[:draw_probability], away: rounded[:away_probability] }
    end

    def parse_time(value)
      return nil if value.to_s.strip.empty?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
