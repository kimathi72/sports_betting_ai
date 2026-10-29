# A stored prediction for one fixture and one MARKET, produced by one model
# version.
#
# MARKETS ARE INDEPENDENT STATEMENTS about the same match, so several coexist:
# a 1X2 prediction and a BTTS prediction are not alternatives, and writing one
# must never overwrite the other. `market` names which question a row answers.
#
# Probabilities describe an OUTCOME of that market. They are NOT betting odds and
# must never be presented as such: odds encode a bookmaker's margin.
#
# HISTORY, NOT A SINGLE ROW PER MATCH+MARKET. A new prediction supersedes the
# previous one for the SAME market (sets `superseded_at`) rather than overwriting
# it. Evaluating a model later requires knowing what it actually said at the time.
# `current` returns live predictions across all markets.
#
# UNIQUENESS. A partial unique index on [match_id, market] WHERE superseded_at IS
# NULL guarantees at most one live prediction per market per match, even for
# concurrent writers. History rows are excluded, so the trail is preserved.
#
# TWO STORAGE SHAPES, ONE MEANING. `outcomes` (jsonb) is the canonical
# distribution keyed by market outcome ("H"/"D"/"A", "over"/"under",
# "yes"/"no", "1x"/"x2"/"12"). The legacy home/draw/away columns remain for 1X2
# so existing endpoints and specs keep working unchanged.
#
# INTEGRITY is enforced twice, deliberately: model validations for useful error
# messages, and PostgreSQL constraints so a bulk write or console SQL cannot store
# an invalid market or a distribution that does not sum to 1.
class Prediction < ApplicationRecord
  OUTCOMES = %w[home draw away].freeze

  # The markets this platform predicts. Closed set, mirroring the ML service.
  MARKETS = %w[1x2 over_under_2.5 btts double_chance].freeze

  # Canonical outcome keys per market. A distribution must contain exactly these.
  MARKET_OUTCOMES = {
    '1x2' => %w[H D A],
    'over_under_2.5' => %w[over under],
    'btts' => %w[yes no],
    'double_chance' => %w[1x x2 12]
  }.freeze

  # Double chance is DERIVED, never predicted by its own classifier: it is a
  # linear combination of the 1X2 probabilities.
  DOUBLE_CHANCE_FROM_1X2 = {
    '1x' => %w[H D],
    'x2' => %w[D A],
    '12' => %w[H A]
  }.freeze

  # Probabilities are stored at 5 decimal places, so their sum can legitimately
  # differ from 1 by a rounding error of at most 3 * 0.000005.
  SUM_TOLERANCE = 0.00002

  belongs_to :match

  validates :market, inclusion: { in: MARKETS }
  validates :model_version, presence: true
  validates :generated_at, presence: true
  validates :home_probability, :draw_probability, :away_probability,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validate :probabilities_must_sum_to_one
  validate :match_must_not_be_completed
  validate :outcomes_must_match_market
  validate :double_chance_must_agree_with_1x2

  scope :current, -> { where(superseded_at: nil) }
  scope :for_market, ->(market) { where(market: market) }

  # Retires the previous live prediction for the SAME market only, BEFORE this row
  # is inserted. Another market's prediction is a different statement about the
  # same match and must survive untouched.
  #
  # ORDER MATTERS: the partial unique index forbids two live rows for one market,
  # so the old row must be retired first. An `after_create` hook would run after
  # the INSERT had already violated the index.
  before_create :supersede_previous

  def probabilities
    {
      "home" => home_probability.to_f,
      "draw" => draw_probability.to_f,
      "away" => away_probability.to_f,
    }
  end

  # The outcome this prediction favours. Ties resolve deterministically by the
  # declared outcome order, so the answer never depends on hash ordering.
  def most_likely_outcome
    OUTCOMES.max_by { |outcome| [public_send(:"#{outcome}_probability").to_f, -OUTCOMES.index(outcome)] }
  end

  def superseded?
    superseded_at.present?
  end

  # The canonical distribution for this row's market. Falls back to the legacy
  # 1X2 columns when `outcomes` is empty, so a row written before this column
  # existed still answers correctly.
  def market_outcomes
    stored = normalised_outcomes || {}
    return stored.transform_values(&:to_f) if stored.any?
    return probabilities.transform_keys { |key| { 'home' => 'H', 'draw' => 'D', 'away' => 'A' }.fetch(key) } if market == '1x2'

    {}
  end

  # The outcome with the highest probability in THIS market. Ties resolve by the
  # market's declared key order so the answer is deterministic.
  def selection
    keys = MARKET_OUTCOMES.fetch(market, [])
    distribution = market_outcomes
    return nil if distribution.empty?

    keys.max_by { |key| [distribution.fetch(key, 0.0), -keys.index(key)] }
  end

  # 1X / X2 / 12 derived from the stored 1X2 probabilities. Derived, never stored
  # on the 1X2 row: a second source of truth would drift.
  def double_chance
    return {} unless market == '1x2'

    h = home_probability.to_f
    d = draw_probability.to_f
    a = away_probability.to_f

    {
      '1x' => round_probability(h + d),
      'x2' => round_probability(d + a),
      '12' => round_probability(h + a)
    }
  end

  private

  def round_probability(value)
    value.round(5)
  end

  # Canonical lower-case outcome keys. The ML service emits double chance as
  # "1X"/"X2"; storing the canonical form means the API never has to care which
  # producer wrote a row. Non-hash values return nil so callers fall back safely.
  def normalised_outcomes
    raw = outcomes.presence
    return nil unless raw.is_a?(Hash)

    # Only double chance is case-insensitive. 1X2's "H"/"D"/"A" are canonical
    # upper-case and must not be folded, or `selection` would stop matching the
    # keys the API documents.
    return raw.transform_keys(&:to_s) unless market == 'double_chance'

    raw.to_h { |key, value| [key.to_s.downcase, value] }
  end

  # A distribution must contain exactly the keys its market defines, each in
  # [0, 1], and sum to 1. Anything else is a malformed provider response that must
  # not be persisted as if it were a real prediction.
  def outcomes_must_match_market
    expected = MARKET_OUTCOMES[market]
    return if expected.nil?

    # Keys are normalised to lower case before comparison. The ML service emits
    # double chance as "1X"/"X2"/"12"; Rails stores the canonical lower-case
    # form, so a caller may legitimately supply either casing.
    distribution = normalised_outcomes
    return if distribution.nil?
    return if distribution.empty? # legacy 1X2 rows use the column triple

    unless distribution.is_a?(Hash)
      errors.add(:outcomes, 'must be an object of outcome probabilities')
      return
    end

    missing = expected - distribution.keys.map(&:to_s)
    extra = distribution.keys.map(&:to_s) - expected
    if missing.any? || extra.any?
      errors.add(:outcomes, "must contain exactly #{expected.join(', ')}")
      return
    end

    values = distribution.transform_keys(&:to_s).transform_values { |v| v.is_a?(Numeric) ? v.to_f : nil }
    if values.value?(nil)
      errors.add(:outcomes, 'probabilities must be numbers')
      return
    end

    unless values.values.all? { |v| v >= 0 && v <= 1 }
      errors.add(:outcomes, 'probabilities must be between 0 and 1')
      return
    end

    # Double chance outcomes OVERLAP by construction: 1X and X2 both contain the
    # draw, so the three probabilities sum to 2, not 1. Requiring a sum of 1 here
    # would make the market unrepresentable. Its real invariant — agreement with
    # the stored 1X2 — is checked by double_chance_must_agree_with_1x2.
    return if market == 'double_chance'

    total = values.values.sum
    return if (total - 1.0).abs <= SUM_TOLERANCE

    errors.add(:base, "market outcome probabilities must sum to 1 (got #{total.round(5)})")
  end

  # Double chance is a projection of 1X2, so it must agree with the 1X2
  # prediction already stored for the same match. A contradicting derivation
  # means one of the two is wrong, and silently keeping both would let the API
  # serve inconsistent answers for one fixture.
  def double_chance_must_agree_with_1x2
    return unless market == 'double_chance'
    return if match.nil?
    return if outcomes.blank?

    reference = Prediction.current.for_market('1x2').find_by(match_id: match_id)
    return if reference.nil?

    expected = reference.double_chance
    supplied = outcomes.transform_keys(&:to_s).transform_values(&:to_f)

    disagreeing = expected.keys.select do |key|
      !supplied.key?(key) || (expected[key] - supplied[key]).abs > SUM_TOLERANCE
    end
    return if disagreeing.empty?

    errors.add(:outcomes, 'double chance contradicts the stored 1x2 prediction for this match')
  end

  def probabilities_must_sum_to_one
    return unless market == "1x2"
    return if home_probability.nil? || draw_probability.nil? || away_probability.nil?

    total = home_probability.to_d + draw_probability.to_d + away_probability.to_d
    return if (total - 1).abs <= SUM_TOLERANCE.to_d

    errors.add(:base, "outcome probabilities must sum to 1 (got #{total.to_f.round(5)})")
  end

  # A prediction for a match that already has a result is not a prediction; it is
  # hindsight, and storing it would poison any evaluation built on this table.
  def match_must_not_be_completed
    return if match.nil?
    return unless match.status == "completed"

    errors.add(:match, "has already been completed, so a prediction cannot be made for it")
  end

  # Runs inside the same transaction as the insert, so a failed save rolls the
  # retirement back and leaves the previous live prediction intact.
  def supersede_previous
    Prediction.where(match_id: match_id, market: market, superseded_at: nil)
              .where.not(id: id)
              .update_all(superseded_at: Time.current)
  end
end
