module Import
  # Chooses which canonical team an ESPN team id refers to.
  #
  # CONSERVATIVE BY DESIGN
  # ----------------------
  # A wrong mapping is far more expensive than a missing one: it files another
  # club's fixtures under a team, which corrupts the table, head-to-head data and
  # every label derived from them. So this returns exactly one candidate or a
  # reason there is none — never a "best guess" among several.
  #
  # WHY A SECOND NORMALISATION
  # --------------------------
  # `Team.normalize` only lowercases. Our names come from the football-data CSV
  # (`Man City`, `Nott'm Forest`) while ESPN sends full names (`Manchester City`,
  # `Nottingham Forest`). Comparison therefore strips punctuation and club-type
  # words first, then applies a fixed multi-level ladder:
  #
  #   1. identical key                          "arsenal"      == "arsenal"
  #   2. identical key ignoring order           "city manchester" vs "manchester city"
  #   3. one key is the other plus a suffix     "mancity"      <= "manchestercity"
  #   4. identical except the last word         "man city"      ~ "man united"
  #
  # Rule 3 is what connects our abbreviations to ESPN's full names. It compares a
  # key against the PREFIX of the longer key, so "man" alone must match the whole
  # of a shorter name to count — a bare fragment is never accepted.
  #
  # Rule 4 only fires when exactly one team shares the remaining words. It is what
  # lets "Sheffield" reach a club at all, and it is deliberately the LAST resort:
  # if two clubs share those words the answer is `:ambiguous` and nothing is
  # written. "Sheffield United" / "Sheffield Wednesday" therefore never merge.
  #
  # `Team.normalize` itself is NOT changed: it is the stored key the CSV importer
  # and the database rely on, and widening it would alter existing row identity.
  class EspnTeamResolver
    # Words that describe what a club IS rather than which club it is.
    CLUB_WORDS = %w[fc afc cf sc club football soccer association athletic].freeze

    # A prefix match shorter than this proves nothing.
    MIN_PREFIX_LENGTH = 3

    REJECT = %i[no_candidate ambiguous].freeze

    # provider_name: ESPN's displayName.
    # teams: candidate canonical teams — normally the clubs of one competition.
    def resolve(provider_name, teams)
      needle = reduce(provider_name.to_s)
      return :no_candidate if needle.empty?

      keys = teams.map { |team| [team, reduce(team.name.to_s)] }
                  .reject { |_team, key| key.empty? }

      # 1. Exact key.
      exact = keys.select { |_team, key| key == needle }
      return exact.first.first if exact.size == 1

      # 2. Same words, different order.
      sorted = sorted_key(needle)
      same_words = keys.select { |_team, key| sorted_key(key) == sorted }
      return same_words.first.first if same_words.size == 1

      # 3. One key is the other with more on the end (abbreviation -> full name).
      prefixed = keys.select { |_team, key| prefix_related?(key, needle) }
      return prefixed.first.first if prefixed.size == 1

      # 4. Same leading words, differing last word — only if unambiguous. This
      #    runs even when steps 2 and 3 found nothing, and yields `:ambiguous`
      #    rather than `:no_candidate` when several clubs share the head word.
      partial = keys.select { |_team, key| same_tail_words?(key, needle) }
      partial.size == 1 ? partial.first.first : (partial.empty? ? :no_candidate : :ambiguous)
    end

    private

    def reduce(name)
      Team.normalize(name)
          .to_s
          .gsub(/[^a-z0-9 ]/, ' ')
          .split
          .reject { |token| CLUB_WORDS.include?(token) }
          .join(' ')
    end

    def sorted_key(key)
      key.split.sort.join(' ')
    end

    # True when the two keys are the same words at different lengths, judged word
    # by word:
    #
    #   "man city"   vs "manchester city"   -> man/manchester, city/city        yes
    #   "man united" vs "manchester united" -> man/manchester, united/united   yes
    #   "man city"   vs "manchester united" -> city/united differ              no
    #   "sheffield"  vs "sheffieldunited"   -> word counts differ (1 vs 2)       no
    #
    # Each word may be an abbreviation of its partner, so the shorter side may be
    # "man" — the guard is that EVERY word must line up, which is what stops a
    # fragment from matching a club it does not fully describe.
    def prefix_related?(a, b)
      words_a = a.split
      words_b = b.split
      return false unless words_a.length == words_b.length
      return false if words_a.empty?

      words_a.zip(words_b).all? do |x, y|
        next true if x == y

        short, long = [x, y].sort_by(&:length)
        short.length >= MIN_PREFIX_LENGTH && long.start_with?(short)
      end
    end

    # True when every word but the last is identical, in either direction.
    #
    # This is what lets a bare head word reach a club at all: "sheffield" vs
    # "sheffield united" shares "sheffield". It is the last resort precisely
    # because it is the least specific, and the caller refuses when it yields
    # more than one club — which is the case that keeps Sheffield United and
    # Sheffield Wednesday apart.
    def same_tail_words?(a, b)
      words_a = a.split
      words_b = b.split
      return false if words_a.empty? || words_b.empty?
      return false if words_a == words_b

      # ONE WORD ON EITHER SIDE IS NOT ENOUGH. "munich" vs "bayern munich" would
      # otherwise compare [] against [] and match every single-word club name,
      # which is how "Bayern Munich" resolved to Inter Milan: both reduce to one
      # word, the heads are both empty, and [] == [] is true.
      #
      # Requiring two words on both sides means this only fires when a head word
      # is genuinely shared, which is the case it exists to serve.
      return false if words_a.length < 2 || words_b.length < 2

      words_a[0..-2] == words_b[0..-2]
    end

    def single(pairs)
      return :no_candidate if pairs.empty?

      pairs.size == 1 ? pairs.first.first : :ambiguous
    end
  end
end
