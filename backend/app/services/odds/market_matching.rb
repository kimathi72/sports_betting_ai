module Odds
  # Provider market/selection names -> our canonical markets and outcome keys.
  #
  # CLOSED AND EXPLICIT. A mis-mapped selection does not fail loudly: it produces a
  # paper bet on the wrong outcome, settles it against the wrong result, and reports
  # a plausible ROI. So every mapping is listed, and anything unrecognised raises
  # rather than being guessed from a substring.
  #
  # CORRECT SCORE IS NOT SUPPORTED. Its selections are scorelines with no fixed set,
  # so there is no "complete market" to price and no overround to remove. Refusing it
  # here is what stops a caller from treating a top-six list as a distribution.
  module MarketMatching
    class UnsupportedMarket < StandardError; end
    class UnsupportedSelection < StandardError; end

    # Canonical markets that can be priced from a bookmaker's odds.
    PRICEABLE = %w[1x2 over_under_2.5 btts double_chance].freeze

    MARKET_ALIASES = {
      "1x2" => "1x2", "1X2" => "1x2", "match_result" => "1x2", "result" => "1x2",
      "over_under_2.5" => "over_under_2.5", "o/u 2.5" => "over_under_2.5",
      "ou2.5" => "over_under_2.5", "totals_2.5" => "over_under_2.5",
      "btts" => "btts", "both_teams_to_score" => "btts", "gg/ng" => "btts",
      "double_chance" => "double_chance", "dc" => "double_chance"
    }.freeze

    SELECTIONS = {
      "1x2" => {
        "h" => "H", "home" => "H", "1" => "H",
        "d" => "D", "draw" => "D", "x" => "D",
        "a" => "A", "away" => "A", "2" => "A"
      },
      "over_under_2.5" => {
        "over" => "over", "over 2.5" => "over", "o2.5" => "over", ">2.5" => "over",
        "under" => "under", "under 2.5" => "under", "u2.5" => "under", "<2.5" => "under"
      },
      "btts" => {
        "yes" => "yes", "gg" => "yes", "y" => "yes",
        "no" => "no", "ng" => "no", "n" => "no"
      },
      "double_chance" => {
        "1x" => "1x", "home or draw" => "1x", "home/draw" => "1x",
        "x2" => "x2", "draw or away" => "x2", "draw/away" => "x2",
        "12" => "12", "home or away" => "12", "home/away" => "12"
      }
    }.freeze

    # football-data.co.uk column families. BTTS is absent because the provider does
    # not publish it — an absence that must be visible, not silently zero.
    FOOTBALL_DATA = {
      "1x2" => { "H" => "H", "D" => "D", "A" => "A" },
      "over_under_2.5" => { "over" => ">2.5", "under" => "<2.5" }
    }.freeze

    class << self
      def market(name)
        key = name.to_s.strip
        return key if PRICEABLE.include?(key)

        canonical = MARKET_ALIASES[key] || MARKET_ALIASES[key.downcase]
        return canonical if canonical

        if key.downcase.include?("correct") || key == "correct_score"
          raise UnsupportedMarket,
                "correct score has no fixed selection set, so it cannot be priced or de-vigged"
        end

        raise UnsupportedMarket, "unknown market #{name.inspect}; known: #{PRICEABLE.join(', ')}"
      end

      def selection(market_name, label)
        canonical_market = market(market_name)
        table = SELECTIONS.fetch(canonical_market)
        key = label.to_s.strip.downcase

        table[key] || raise(UnsupportedSelection,
                            "#{label.inspect} is not a selection of #{canonical_market}; " \
                            "known: #{table.values.uniq.join(', ')}")
      end

      def complete?(market_name, selections)
        canonical_market = market(market_name)
        expected = SELECTIONS.fetch(canonical_market).values.uniq.sort
        Array(selections).map(&:to_s).sort == expected
      end

      # Column names for one bookmaker prefix, e.g. "B365" -> B365H/B365D/B365A.
      # `closing: true` selects the C-prefixed closing columns.
      def football_data_columns(bookmaker, closing: false)
        prefix = closing ? "#{bookmaker}C" : bookmaker.to_s

        FOOTBALL_DATA.each_with_object({}) do |(market_name, columns), result|
          result[market_name] = columns.transform_values { |suffix| "#{prefix}#{suffix}" }
        end
      end
    end
  end
end
