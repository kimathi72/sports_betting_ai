module Predictions
  # Selects the matches a model may legitimately learn from when predicting one
  # fixture.
  #
  # WHY THIS EXISTS. The ML service computes the 17-feature vector from a match
  # plus a history list. If that list contains a result that was not known at
  # kickoff, the feature vector is contaminated and every reported metric is
  # optimistic. This service is the single place that decides what counts as
  # "history", so the rule cannot drift between callers.
  #
  # THE RULE, in order of strictness:
  #
  #   1. `kickoff_at < fixture.kickoff_at` — STRICTLY before. A fixture kicking
  #      off at the same instant is not history: its result was not known when
  #      this match started.
  #   2. `status = 'completed'` — an unplayed or postponed fixture has no result
  #      to learn from.
  #   3. both scores present — belt and braces; the schema enforces it, but a
  #      half-written row must never reach the model.
  #   4. only matches involving one of the two clubs — an unrelated fixture tells
  #      the model nothing and only inflates the payload.
  #   5. bounded to the most recent `PER_TEAM_LIMIT` per club, capped at `LIMIT`.
  #
  # This class deliberately does NOT compute features. Kilo's
  # `compute_match_features` owns that, and duplicating it here would create two
  # implementations that silently disagree about the same match.
  class MatchHistory
    # The ML feature set uses last-5 form, so five completed matches per club is
    # the useful minimum. A few extra gives head-to-head coverage without turning
    # the payload into the whole archive.
    PER_TEAM_LIMIT = 10

    # Hard cap on the returned array, whatever the per-team limits add up to.
    LIMIT = 40

    # Fields the ML service reads. Anything else is omitted on purpose: the
    # history payload should not become a second copy of the matches endpoint.
    FIELDS = %w[id kickoff_at status home_team_id away_team_id home_score away_score].freeze

    def self.for(match)
      new(match).call
    end

    def initialize(match)
      @match = match
    end

    attr_reader :match

    # Returns an array of hashes, oldest first, ready to be embedded in the ML
    # request body.
    def call
      kickoff = match.kickoff_at
      # A fixture without a kickoff has no defined "before", so nothing can be
      # safely called history. Returning [] is the conservative answer: the model
      # then sees a fixture with no form rather than an arbitrary subset.
      return [] if kickoff.nil?

      candidates = relevant_completed_before(kickoff)
      recent = most_recent_per_team(candidates)

      recent.sort_by { |m| [m.kickoff_at, m.id] }.last(LIMIT).map { |m| serialize(m) }
    end

    private

    def relevant_completed_before(kickoff)
      Match.where(status: 'completed')
           .where('kickoff_at < ?', kickoff)
           .where('home_team_id IN (?) OR away_team_id IN (?)',
                  [match.home_team_id, match.away_team_id],
                  [match.home_team_id, match.away_team_id])
           .where.not(id: match.id)
           .where.not(home_score: nil)
           .where.not(away_score: nil)
           .order(kickoff_at: :desc, id: :desc)
           .to_a
    end

    # The query returns newest first, so the first N seen for a club are its most
    # recent N.
    #
    # The quota is applied per club on EVERY row, not only when all involved clubs
    # are full. Without that, a club's older matches leak in through rows where
    # the *other* club still had quota — which is exactly the case for the two
    # clubs being predicted, since both accumulate history together.
    def most_recent_per_team(candidates)
      per_team = Hash.new(0)
      selected = []

      candidates.each do |candidate|
        teams = [candidate.home_team_id, candidate.away_team_id].uniq
        # Drop the row if any involved club has already reached its quota.
        next if teams.any? { |team| per_team[team] >= PER_TEAM_LIMIT }

        selected << candidate
        teams.each { |team| per_team[team] += 1 }
        break if selected.length >= LIMIT
      end

      selected
    end

    def serialize(record)
      {
        'id' => record.id,
        'kickoff_at' => record.kickoff_at.utc.iso8601,
        'status' => record.status,
        'home_team_id' => record.home_team_id,
        'away_team_id' => record.away_team_id,
        'home_score' => record.home_score,
        'away_score' => record.away_score
      }
    end
  end
end
