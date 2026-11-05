module Import
  # Discovers which canonical team each ESPN team id refers to, for ANY competition.
  #
  # WHY THIS EXISTS
  # ---------------
  # The original mapping task was per-league and per-human: read the roster, decide
  # 20 names by eye, write a script. The identity problem is identical for all nine
  # unmapped competitions, so the work belongs in one rule-driven service that takes
  # the competition's club list as input.
  #
  # IDENTITY IS NOT A SCORE
  # -----------------------
  # A candidate is accepted only through Import::EspnTeamResolver's ordered lexical
  # ladder (identical key -> same words -> abbreviation -> shared head word), which
  # returns exactly one club or a refusal. Nothing here uses a similarity threshold,
  # because the wrong side of a threshold merges two real clubs.
  #
  # Names that share no lexical evidence (our "Ath Bilbao" vs ESPN's "Athletic Club")
  # cannot be derived at all. Those are supplied by the caller as `evidence`, with a
  # stated basis, and are recorded as :evidence rather than :exact so the audit trail
  # distinguishes a rule from a human decision.
  #
  # RESULTS (never silently merged)
  #   :existing  — already mapped, and the mapping agrees
  #   :verified  — one candidate, via a rule (:exact) or supplied evidence (:evidence)
  #   :ambiguous — two or more candidates; NOT mapped
  #   :conflict  — the provider id is already mapped to a different club; NOT changed
  #   :unmapped  — no candidate at all
  #   :invalid   — provider team without a usable id
  class EspnTeamIdentity
    Resolver = Import::EspnTeamResolver

    def initialize(canonical:, provider_teams:, evidence: {}, existing_mappings: {})
      @canonical = Array(canonical)
      @provider_teams = Array(provider_teams)
      # provider display name => { canonical: "our name", basis: "why we believe it" }
      @evidence = evidence || {}
      # provider team id => canonical team id, for mappings that already exist
      @existing_mappings = existing_mappings || {}
      @resolver = Resolver.new
    end

    def call
      result = Hash.new { |h, k| h[k] = [] }
      seen_canonical = {}

      @provider_teams.each do |provider|
        provider_id = provider["id"].to_s
        provider_name = provider["displayName"].to_s

        if provider_id.empty? || provider_name.empty?
          result[:invalid] << provider_name
          next
        end

        # 1. An existing mapping wins over any lexical guess, or is reported as a
        #    conflict when it disagrees. Existing identity is never overwritten.
        if @existing_mappings.key?(provider_id)
          existing_target = @existing_mappings[provider_id]
          club = @canonical.find { |t| t.id == existing_target }
          if club
            result[:existing] << { provider_id: provider_id, provider_name: provider_name, canonical: club }
          else
            result[:conflicts] << {
              provider_id: provider_id, provider_name: provider_name,
              reason: "already mapped to team #{existing_target}, which is not in this competition"
            }
          end
          next
        end

        candidate, basis = candidate_for(provider_name)
        if candidate.is_a?(Symbol)
          # The resolver speaks :no_candidate; the caller-facing vocabulary is
          # :unmapped. Normalised here so callers never match on resolver internals.
          key = candidate == :no_candidate ? :unmapped : :ambiguous
          result[key] << { provider_id: provider_id, provider_name: provider_name }
          next
        end

        # 2. One canonical club may not receive two provider ids.
        if seen_canonical.key?(candidate.id)
          result[:ambiguous] << {
            provider_id: provider_id, provider_name: provider_name,
            reason: "already claimed by provider id #{seen_canonical[candidate.id]}"
          }
          next
        end

        seen_canonical[candidate.id] = provider_id
        result[:matched] << {
          provider_id: provider_id, provider_name: provider_name,
          canonical: candidate, status: :verified, basis: basis
        }
      end

      result
    end

    private

    # Returns [Team, basis] or [Symbol, nil].
    def candidate_for(provider_name)
      # Evidence is keyed by the NORMALISED provider name, so an accented form
      # ("Atlético Madrid") is found under "atletico madrid" and a caller cannot
      # miss an entry by spelling it differently.
      explicit = @evidence[provider_name] || @evidence[Team.normalize(provider_name).to_s] ||
                 @evidence[provider_name.to_s]
      if explicit
        club = @canonical.find { |t| t.name == explicit[:canonical] }
        return [:ambiguous, nil] if club.nil?

        return [club, :evidence]
      end

      resolved = @resolver.resolve(provider_name, @canonical)
      return [resolved, :exact] if resolved.is_a?(Team)

      [resolved, nil] # :ambiguous or :no_candidate
    end
  end
end
