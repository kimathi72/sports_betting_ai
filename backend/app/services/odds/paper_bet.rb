module Odds
  # A would-be bet: what we would have staked, at what price, and what happened.
  #
  # IMMUTABLE ONCE SETTLED. `settle` returns a NEW object rather than mutating this
  # one, for the same reason a prediction is immutable: the record of what we
  # believed before the result must not be rewritable after it. A settled bet that
  # could be re-settled would let a losing ledger be edited into a winning one.
  #
  # NO MONEY MOVES. This class computes numbers. It has no provider, no account and
  # no execution path, and it must never grow one.
  #
  # WHAT A POSITIVE EV MEANS HERE: nothing about the future. It is the model's
  # probability priced against a bookmaker's. If the probability is uncalibrated,
  # the EV is an opinion, not an edge.
  class PaperBet
    class InvalidOutcome < StandardError; end
    class AlreadySettled < StandardError; end

    # Which outcomes win a given selection. Double Chance is the reason this is a
    # table rather than an equality check: 1X wins on H OR D.
    WINNING_OUTCOMES = {
      "1x2" => { "H" => %w[H], "D" => %w[D], "A" => %w[A] },
      "over_under_2.5" => { "over" => %w[over], "under" => %w[under] },
      "btts" => { "yes" => %w[yes], "no" => %w[no] },
      "double_chance" => { "1x" => %w[H D], "x2" => %w[D A], "12" => %w[H A] }
    }.freeze

    attr_reader :market, :selection, :decimal_odds, :stake, :model_probability,
                :actual_outcome, :closing_odds, :errors

    def initialize(market:, selection:, decimal_odds:, stake:, model_probability: nil)
      @market = market.to_s
      @selection = selection.to_s
      @decimal_odds = decimal_odds
      @stake = stake
      @model_probability = model_probability
      @errors = []
      validate!
    end

    def valid?
      errors.empty?
    end

    def settled?
      !actual_outcome.nil?
    end

    def won?
      return false unless settled?

      WINNING_OUTCOMES.fetch(market).fetch(selection).include?(actual_outcome)
    end

    def lost?
      settled? && !won?
    end

    def profit
      return nil unless settled?

      won? ? stake.to_f * (decimal_odds.to_f - 1.0) : -stake.to_f
    end

    def returned
      return nil unless settled?

      won? ? stake.to_f * decimal_odds.to_f : 0.0
    end

    def expected_value
      return nil if model_probability.nil?

      OddsMath.expected_value(model_probability: model_probability, decimal_odds: decimal_odds, stake: stake)
    end

    def closing_line_value
      return nil if closing_odds.nil?

      OddsMath.closing_line_value(taken_odds: decimal_odds, closing_odds: closing_odds)
    end

    # Returns a NEW settled bet. The receiver is untouched.
    def settle(actual_outcome:, closing_odds: nil)
      raise AlreadySettled, "this bet is already settled as #{actual_outcome.inspect}" if settled?

      outcome = actual_outcome.to_s
      unless WINNING_OUTCOMES.fetch(market).values.flatten.uniq.include?(outcome)
        raise InvalidOutcome, "#{outcome.inspect} is not an outcome of #{market}"
      end

      self.class.new(market: market, selection: selection, decimal_odds: decimal_odds,
                     stake: stake, model_probability: model_probability).tap do |copy|
        copy.instance_variable_set(:@actual_outcome, outcome)
        copy.instance_variable_set(:@closing_odds, closing_odds)
      end
    end

    # Portfolio view. Unsettled bets are excluded from every total, so a ledger with
    # pending bets cannot report a profit it has not earned.
    def self.summarise(bets)
      settled = Array(bets).select(&:settled?)
      staked = settled.sum { |bet| bet.stake.to_f }
      returned = settled.sum { |bet| bet.returned.to_f }
      profit = returned - staked

      {
        bets: settled.size,
        staked: staked,
        returned: returned,
        profit: profit,
        roi: staked.zero? ? 0.0 : profit / staked,
        wins: settled.count(&:won?),
        losses: settled.count(&:lost?)
      }
    end

    private

    def validate!
      begin
        canonical_market = MarketMatching.market(market)
        @market = canonical_market
        @selection = MarketMatching.selection(canonical_market, selection)
      rescue MarketMatching::UnsupportedMarket, MarketMatching::UnsupportedSelection => e
        errors << e.message
        return
      end

      errors << "decimal odds must be > 1 (got #{decimal_odds.inspect})" unless OddsMath.valid_decimal_odds?(decimal_odds)
      errors << "stake must be positive (got #{stake.inspect})" unless stake.is_a?(Numeric) && stake.positive?

      return if model_probability.nil?

      unless model_probability.is_a?(Numeric) && model_probability.between?(0.0, 1.0)
        errors << "model probability must be within [0,1] (got #{model_probability.inspect})"
      end
    end
  end
end
