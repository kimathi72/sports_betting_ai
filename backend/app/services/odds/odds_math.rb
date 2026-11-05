module Odds
  # Decimal-odds arithmetic: margin, fair probability, expected value, CLV.
  #
  # PURE. No database, no provider, no model. Every function takes numbers and
  # returns numbers, so each one can be checked against a hand calculation and no
  # caller can accidentally "correct" a bookmaker's price on the way to storage.
  #
  # DECIMAL ODDS ONLY. Fractional and American formats are converted at the
  # ingestion boundary, never here: one representation means one place to be wrong.
  #
  # WHAT THIS DOES NOT DO
  # ---------------------
  # It does not decide whether a bet is good. A positive expected value computed
  # from an UNCALIBRATED model probability is not evidence of an edge — it is the
  # model's opinion priced against a bookmaker's. The caller must know which
  # probabilities it is passing in.
  module OddsMath
    # A market whose selections partition the outcome space (exactly one can win).
    PARTITION_MARKETS = %w[1x2 over_under_2.5 btts].freeze

    # Markets whose selections OVERLAP. Double Chance is the canonical case: 1X and
    # X2 both win on a draw, so their implied probabilities sum to about 2 and the
    # "overround" is not a margin at all.
    OVERLAPPING_MARKETS = %w[double_chance].freeze

    # A bookmaker's overround below 1.0 means they would lose on every outcome.
    # That is a parsing or mapping error, never a gift, and must not become EV.
    MIN_OVERROUND = 1.0
    # Above this, the "odds" are almost certainly not decimal odds (e.g. American
    # +150 read as 150, or a percentage). Refusing is cheaper than debugging a
    # reported ROI later.
    MAX_OVERROUND = 3.0

    class InvalidMarket < StandardError; end
    class NotAPartition < StandardError; end

    class << self
      def valid_decimal_odds?(value)
        number = to_number(value)
        !number.nil? && number > 1.0 && number.finite?
      end

      # Sum of implied probabilities. > 1 means the bookmaker holds a margin.
      def overround(odds)
        prices = normalize(odds)
        raise ArgumentError, "a market needs at least two selections (got #{prices.size})" if prices.size < 2

        prices.values.sum { |price| 1.0 / price }
      end

      # Fair probabilities by proportional (multiplicative) normalisation.
      #
      # Proportional is the default because it is simple and conservative. Shin's
      # method models favourite-longshot bias better and is a documented variant to
      # evaluate later — not an assumed improvement.
      #
      # `odds` is a positional hash on purpose: `de_vig("H" => 2.1, "D" => 3.4)` is
      # the natural call, and a keyword-only signature would reject it. The `**`
      # splat is what makes that work — without it Ruby 3 treats the bare hash as
      # keyword arguments and raises "wrong number of arguments (given 0)".
      def de_vig(odds = nil, market: nil, **odds_keywords)
        odds = odds_keywords if odds.nil? && odds_keywords.any?
        raise ArgumentError, "odds must be a hash of selection => decimal odds" if odds.nil?

        # Infer the market from the selection keys when the caller did not name it.
        # A caller that forgets `market:` must not silently get a normalised
        # Double Chance, which is the exact error this guard exists to prevent.
        market ||= infer_market(odds)

        if market && OVERLAPPING_MARKETS.include?(market.to_s)
          raise NotAPartition,
                "#{market} selections overlap (1X and X2 both win on a draw); its implied " \
                "probabilities do not sum to a bookmaker margin. Derive it from the " \
                "de-vigged 1X2 instead."
        end

        prices = normalize(odds)
        total = prices.values.sum { |price| 1.0 / price }

        unless total.between?(MIN_OVERROUND, MAX_OVERROUND)
          raise InvalidMarket,
                "overround #{total.round(4)} is outside [#{MIN_OVERROUND}, #{MAX_OVERROUND}]; " \
                "these are probably not decimal odds for a complete market"
        end

        prices.transform_values { |price| (1.0 / price) / total }
      end

      # Expected value per unit staked.
      #
      #   EV = p * (odds - 1) - (1 - p)  ==  p * odds - 1
      #
      # Positive means the price pays more than the probability implies. It says
      # nothing about whether the probability is right.
      def expected_value(model_probability:, decimal_odds:, stake: 1.0)
        probability = to_number(model_probability)
        unless probability && probability.between?(0.0, 1.0)
          raise ArgumentError, "probability must be within [0,1] (got #{model_probability.inspect})"
        end
        raise ArgumentError, "decimal odds must be > 1 (got #{decimal_odds.inspect})" unless valid_decimal_odds?(decimal_odds)

        (probability * to_number(decimal_odds) - 1.0) * to_number(stake)
      end

      # Closing line value: how much better the taken price was than the close.
      #
      #   CLV = taken / closing - 1
      #
      # Positive means the market moved towards our position after we took it. It is
      # the cheapest available signal of skill, and it is NOT a profit measure: a
      # bet can beat the close and still lose.
      def closing_line_value(taken_odds:, closing_odds:)
        unless valid_decimal_odds?(taken_odds) && valid_decimal_odds?(closing_odds)
          raise ArgumentError, "both prices must be decimal odds > 1"
        end

        (to_number(taken_odds) / to_number(closing_odds)) - 1.0
      end

      private

      # Selection keys are canonical (`1x`, `x2`, `12`), so the market is
      # identifiable without a second argument.
      def infer_market(odds)
        return nil unless odds.is_a?(Hash)

        keys = odds.keys.map { |key| key.to_s.downcase }
        return "double_chance" if (keys & %w[1x x2 12]).size >= 2

        nil
      end

      def normalize(odds)
        raise ArgumentError, "odds must be a hash of selection => decimal odds" unless odds.is_a?(Hash)

        # `to_h` with a block is not available on every Hash-like input, and a
        # plain `each_with_object` keeps the insertion order the caller supplied.
        odds.each_with_object({}) do |(selection, price), result|
          raise ArgumentError, "invalid decimal odds for #{selection.inspect}: #{price.inspect}" unless valid_decimal_odds?(price)

          result[selection.to_s] = to_number(price)
        end
      end

      def to_number(value)
        return value.to_f if value.is_a?(Numeric)
        return nil if value.nil?

        Float(value.to_s.strip)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
