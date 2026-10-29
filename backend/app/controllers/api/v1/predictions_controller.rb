module Api
  module V1
    # Read-only access to stored 1X2 predictions.
    #
    # READ ONLY BY DESIGN. Inference is requested through PredictMatchJob. A GET
    # that called the model would make this endpoint depend on a second service
    # being up, and would let any client generate model work by refreshing.
    #
    # DEFAULT IS CURRENT ONLY. Superseded predictions stay in the table because
    # evaluation needs them, but a normal client wants the latest belief about a
    # fixture. `include_history=true` exposes the full trail.
    #
    # Probabilities are HOME / DRAW / AWAY, never odds. They are emitted both as
    # three named fields (stable, explicit) and as a `probabilities` object
    # (convenient for the ML service's own naming).
    class PredictionsController < ApplicationController
      DEFAULT_LIMIT = 500
      MAX_LIMIT = 2000

      # Requests predictions for one match and one or more markets.
      #
      # The controller validates the request, delegates every probability
      # decision to Predictions::MarketPredictor, and reports the outcome. It
      # computes nothing itself, so the API and the background job share one
      # implementation.
      #
      # Markets are INDEPENDENT: one failing must not discard another's result, so
      # a partial success returns 207 with the failures listed by market.
      def create
        # A missing match_id is a malformed request (400), not a missing resource:
        # without it there is nothing to look up.
        if params[:match_id].blank?
          return render_error('match_id is required', :bad_request)
        end

        match = Match.find_by(id: params[:match_id])
        if match.nil?
          return render_error("match #{params[:match_id].inspect} not found", :not_found)
        end

        if match.status == 'completed'
          return render_error('a completed match already has a result and cannot be predicted',
                              :unprocessable_entity)
        end

        markets = requested_markets
        return if performed?

        predictor = Predictions::MarketPredictor.new

        created = []
        errors = {}

        markets.each do |market|
          result = predictor.call(match, market: market)
          if result.success?
            created << result.prediction
          else
            errors[market] = result.message
          end
        end

        if created.empty?
          status = errors.values.any? { |m| m.to_s.match?(/unreachable|timed out|HTTP 5\d\d/) } ? :service_unavailable : :unprocessable_entity
          return render json: { match_id: match.id, error: errors.values.first, errors: errors }, status: status
        end

        status = errors.empty? ? :created : :multi_status
        render json: {
          match_id: match.id,
          predictions: created.map { |prediction| serialize_market(prediction) },
          errors: errors
        }, status: status
      end

      def index
        market = market_param
        return if performed?

        predictions = scope
        predictions = predictions.for_market(market) if market
        predictions = predictions.order(generated_at: :desc, id: :desc).limit(requested_limit)

        render json: predictions.map { |prediction| serialize(prediction) }
      end

      # `:id` is the MATCH id: a client asks "what does the model think about this
      # fixture?". All CURRENT markets are returned, because a match legitimately
      # has several independent predictions at once.
      def show
        market = market_param
        return if performed?

        relation = Prediction.current.where(match_id: params[:id])
        relation = relation.for_market(market) if market
        predictions = relation.order(:market)

        if predictions.empty?
          render json: { error: "no current prediction for match #{params[:id]}" },
                 status: :not_found
          return
        end

        render json: {
          match_id: params[:id].to_i,
          predictions: predictions.map { |prediction| serialize_market(prediction) }
        }
      end

      private

      def render_error(message, status)
        render json: { error: message }, status: status
      end

      # Markets to predict. Defaults to every market when unspecified is NOT
      # allowed: an accidental request should not silently generate four
      # expensive model calls.
      def requested_markets
        raw = params[:markets].presence || params[:market].presence
        if raw.nil?
          render_error("markets is required, one or more of: #{Prediction::MARKETS.join(', ')}",
                       :bad_request)
          return []
        end

        list = Array(raw).map(&:to_s)
        unknown = list - Prediction::MARKETS
        unless unknown.empty?
          render_error("unsupported market(s): #{unknown.join(', ')}; supported: #{Prediction::MARKETS.join(', ')}",
                       :bad_request)
          return []
        end

        list.uniq
      end

      # Returns a validated market name, or nil after rendering a 400. Rendering
      # does not halt the action, so the caller must check `performed?`.
      def market_param
        raw = params[:market].presence
        return nil if raw.nil?
        return raw if Prediction::MARKETS.include?(raw)

        render json: { error: "market must be one of: #{Prediction::MARKETS.join(', ')}" },
               status: :bad_request
        nil
      end

      # The market-level view: one entry per market, with its own canonical
      # outcome keys. Kept separate from `serialize` so the collection response
      # stays backwards compatible.
      def serialize_market(prediction)
        {
          market: prediction.market,
          selection: prediction.selection,
          probabilities: prediction.market_outcomes,
          model_version: prediction.model_version,
          generated_at: prediction.generated_at.utc.iso8601
        }
      end

      def scope
        relation = include_history? ? Prediction.all : Prediction.current
        relation = relation.where(match_id: params[:match_id]) if params[:match_id].present?
        relation = relation.where(model_version: params[:model_version]) if params[:model_version].present?
        relation
      end

      def include_history?
        ActiveModel::Type::Boolean.new.cast(params[:include_history]) == true
      end

      def requested_limit
        raw = params[:limit].presence
        return DEFAULT_LIMIT if raw.nil?

        limit = Integer(raw, 10)
        return MAX_LIMIT if limit > MAX_LIMIT
        return DEFAULT_LIMIT if limit < 1

        limit
      rescue ArgumentError
        DEFAULT_LIMIT
      end

      def serialize(prediction)
        {
          id: prediction.id,
          match_id: prediction.match_id,
          # Added so the collection can be filtered/consumed per market. Existing
          # keys are unchanged, so current clients keep working.
          market: prediction.market,
          model_version: prediction.model_version,
          home_probability: prediction.home_probability.to_f,
          draw_probability: prediction.draw_probability.to_f,
          away_probability: prediction.away_probability.to_f,
          probabilities: prediction.market_outcomes,
          selection: prediction.selection,
          most_likely_outcome: prediction.most_likely_outcome,
          generated_at: prediction.generated_at.utc.iso8601,
        }
      end
    end
  end
end
