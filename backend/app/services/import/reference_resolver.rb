module Import
  # Maps provider identity onto canonical Phase 3 records through
  # ExternalIdentifier, creating records only when no verified mapping exists.
  #
  # WHY MAPPINGS, NOT NAMES. football-data.co.uk has no stable numeric id for a
  # competition or a club: it sends a division code ("E0") and the text of a team
  # name. Treating display text as identity would merge two real clubs that
  # happen to be spelled alike, or split one club that is spelled two ways. So
  # every resolution here goes through an ExternalIdentifier in this provider's
  # namespace. Display names are used only to *create* a canonical record on
  # first sight, never to *find* an existing one.
  #
  # The resolver deliberately does not open a transaction. It is called by
  # MatchImporter, which owns the batch transaction, so a failed batch rolls back
  # the reference rows this class created. Opening a nested transaction here
  # would only add savepoint churn.
  #
  # CONCURRENCY. A lookup followed by an insert is not atomic: two importers can
  # both miss, both insert, and one loses on the database's unique index. That
  # race is expected and recoverable — the winning row is re-read and reused.
  # Only `ActiveRecord::RecordNotUnique` is treated this way; other database
  # errors are real failures and are reported, never swallowed.
  class ReferenceResolver
    # Raised by `resolve_or_raise` when a row cannot be resolved. The importer
    # uses the non-raising methods; this exists for callers that prefer to fail
    # fast (CLI smoke checks, console work).
    class ResolutionError < StandardError; end

    # Provider namespaces are explicit strings because they are persisted in
    # ExternalIdentifier.provider and must stay stable across releases.
    KNOWN_PROVIDERS = %w[football_data].freeze

    # A season label is the operator's own label ("2024/25"), not a provider
    # format. The shape is checked so an obvious typo is caught before it becomes
    # a canonical Season row; it is not an attempt to validate every league's
    # convention.
    SEASON_LABEL_PATTERN = %r{\A(\d{4})(?:/(\d{2}|\d{4}))?\z}.freeze

    # A season identifier is scoped by competition because two competitions can
    # both have a "2024/25" season. Keeping the competition id in the external id
    # makes that scoping visible in the stored value as well as the uniqueness
    # index.
    def self.season_external_id(competition_id, season_label)
      "season:#{competition_id}:#{season_label}"
    end

    def initialize(provider:)
      @provider = provider.to_s
    end

    attr_reader :provider

    # Resolves the provider's competition code (e.g. "E0") to a Competition.
    #
    # The canonical name is seeded from the code on first sight. That is
    # deliberately *not* treated as identity: a later, richer name can be added
    # by an operator without changing which competition the code refers to.
    #
    # The lookup column is read from the same Constant that is written, so this
    # method cannot disagree with itself about which competition a mapping means.
    def resolve_competition(code)
      key = normalize_key(code)
      return Resolution.failure('competition code is missing') if key.empty?

      identifier = find_identifier(:competition, key)

      if identifier
        unless canonical_name_matches?(identifier.competition, key)
          return mapping_conflict(:competition, key, identifier.competition)
        end

        return Resolution.success(identifier.competition, created: false)
      end

      existing = Competition.find_by(name: canonical_competition_name(key))
      if existing
        # A migration or hand-seeded competition already owns this identity.
        # Attach the provider mapping to it rather than creating a second row
        # that the name uniqueness would not allow anyway.
        begin
          persist_identifier(:competition, key, existing)
        rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
          return recover_from_competition_race(key, e)
        end

        return Resolution.success(existing, created: false)
      end

      # The mapping insert and the canonical insert each have their own unique
      # index. A concurrent writer may win either one, so both are recoverable:
      # the winner is re-read and reused instead of reporting a spurious failure.
      # The model also validates name uniqueness, so a race can surface as a
      # RecordInvalid("already been taken") instead of RecordNotUnique.
      record = begin
        Competition.create!(name: canonical_competition_name(key))
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        return recover_from_competition_race(key, e)
      end

      begin
        persist_identifier(:competition, key, record)
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        return recover_from_competition_race(key, e)
      end

      Resolution.success(record, created: true)
    rescue ActiveRecord::StatementInvalid
      Resolution.failure('competition could not be stored because of a database error')
    end

    # A uniqueness failure on either the name or the mapping means another writer
    # got there first. Only those are recovered; any other validation failure is a
    # real error and is reported rather than hidden behind a retry.
    def recover_from_competition_race(key, error)
      unless uniqueness_failure?(error)
        return Resolution.failure(
          "competition could not be stored: #{error.record.errors.full_messages.to_sentence}"
        )
      end

      recover_from_race(:competition, key) do
        Competition.find_by(name: canonical_competition_name(key))
      end
    end

    # True when a RecordInvalid was caused by a uniqueness validator, which is the
    # application-level twin of a unique-index violation.
    def uniqueness_failure?(error)
      return true if error.is_a?(ActiveRecord::RecordNotUnique)
      return false unless error.is_a?(ActiveRecord::RecordInvalid)

      error.record.errors.details.values.flatten.any? { |detail| detail[:error] == :taken }
    end

    # Resolves the operator's season label within a competition.
    #
    # The label is supplied by the import run. Deriving it from fixture dates
    # would guess wrong at season boundaries and make the import irreproducible.
    def resolve_season(competition, label)
      return Resolution.failure('season requires a competition') unless competition.is_a?(Competition)
      return Resolution.failure('season requires a competition') if competition.new_record?

      text = label.to_s.strip
      return Resolution.failure('season label is missing') if text.empty?

      unless text.match?(SEASON_LABEL_PATTERN)
        return Resolution.failure("season label is not a recognised season: #{text.inspect}")
      end

      external_id = self.class.season_external_id(competition.id, text)

      resolution = mapped(:season, external_id) do
        # Team.normalize-style tolerance for label formatting differences is
        # deliberately NOT applied: the label is the operator's explicit input.
        Season.create!(competition: competition, name: text)
      end

      return resolution if resolution.failure?

      # A season mapping is scoped to its competition. If this provider id was
      # already mapped under a different competition the mapping is contradictory.
      return resolution if resolution.record.competition_id == competition.id

      Resolution.failure("season #{text.inspect} is already mapped to another competition")
    end

    # Resolves a provider team name to a canonical Team.
    #
    # Canonical identity is `Team.normalize` (transliterate, downcase, collapse
    # whitespace, trim), which is what the Phase 3 unique index enforces. Two
    # different display names that normalise to the same identity would collide
    # on that index; rather than let PostgreSQL raise, that is reported as an
    # explicit collision so an operator can decide whether the names are the same
    # club.
    def resolve_team(name)
      display = name.to_s.strip
      return Resolution.failure('team name is missing') if display.empty?

      # The provider key is the *normalised* name, so "  manchester   UNITED "
      # and "Manchester United" are one mapping rather than two lookups that
      # both miss. The display name is stored on the canonical Team.
      key = Team.normalize(display)
      identifier = find_identifier(:team, key)
      return Resolution.success(identifier.team, created: false) if identifier

      existing = find_canonical_team(display)
      if existing
        # Only case/whitespace variants may adopt an existing canonical row.
        # A materially different name is an operator decision, not a guess.
        if meaningful_difference?(existing.name, display)
          return Resolution.failure(team_collision_message(existing, display))
        end

        begin
          persist_identifier(:team, key, existing)
        rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
          return recover_from_team_race(key, display, e)
        end

        return Resolution.success(existing, created: false)
      end

      # As with competitions, either unique index may be won by a concurrent
      # writer: the canonical normalized_name or the provider mapping.
      record = begin
        Team.create!(name: display)
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        return recover_from_team_race(key, display, e)
      end

      begin
        persist_identifier(:team, key, record)
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        return recover_from_team_race(key, display, e)
      end

      Resolution.success(record, created: true)
    rescue ActiveRecord::StatementInvalid
      Resolution.failure('team could not be stored because of a database error')
    end

    def recover_from_team_race(key, display, error)
      unless uniqueness_failure?(error)
        return Resolution.failure(
          "team could not be stored: #{error.record.errors.full_messages.to_sentence}"
        )
      end

      recover_from_race(:team, key) { find_canonical_team(display) }
    end

    # Resolves the fixture. The natural key (computed by the provider adapter)
    # is the match identity because the source publishes no match id.
    #
    # Any Match-level validation the database or model would reject is reported
    # as a resolution failure with the invalid row's reason, not as an exception.
    def resolve_match(row, competition:, season:, home_team:, away_team:)
      return Resolution.failure('match requires a competition') unless competition.is_a?(Competition)
      return Resolution.failure('match requires a season') unless season.is_a?(Season)
      return Resolution.failure('match requires both teams') if home_team.nil? || away_team.nil?

      key = match_external_id(row, competition, season)
      return Resolution.failure('match provider key is missing') if row.provider_key.to_s.strip.empty?

      if row.status.to_s.strip.empty? || !Match::STATUSES.include?(row.status)
        return Resolution.failure("unsupported match status: #{row.status.inspect}")
      end

      if season.competition_id != competition.id
        return Resolution.failure('season does not belong to the match competition')
      end

      if home_team.id == away_team.id
        return Resolution.failure('home and away teams must differ')
      end

      mapped(:match, key) do
        build_match(row, competition: competition, season: season,
                         home_team: home_team, away_team: away_team)
      end
    end

    # Resolves an entire row: competition, season, both teams, then the match.
    # The returned Resolution carries every record so the importer can report
    # without repeating lookups.
    def resolve_row(row, season_label:)
      competition = resolve_competition(row.competition_code)
      return competition if competition.failure?

      season = resolve_season(competition.record, season_label)
      return attach(season, competition: competition.record) if season.failure?

      home = resolve_team(row.home_team_name)
      return attach(home, competition: competition.record, season: season.record) if home.failure?

      away = resolve_team(row.away_team_name)
      if away.failure?
        return attach(away, competition: competition.record, season: season.record,
                            home_team: home.record)
      end

      match = resolve_match(row, competition: competition.record, season: season.record,
                                 home_team: home.record, away_team: away.record)

      return attach(match, competition: competition.record, season: season.record,
                           home_team: home.record, away_team: away.record) if match.failure?

      Resolution.success(
        match.record,
        created: match.created_record?,
        competition: competition.record,
        season: season.record,
        home_team: home.record,
        away_team: away.record,
        match: match.record
      )
    end

    def resolve_or_raise(row, season_label:)
      resolution = resolve_row(row, season_label: season_label)
      raise ResolutionError, resolution.error if resolution.failure?

      resolution.match
    end


    private

    # Two different display names sharing one normalised identity.
    class TeamCollision < StandardError
      def initialize(existing, attempted)
        @existing = existing
        @attempted = attempted
        super(
          "team name collision: #{attempted.inspect} has the same canonical identity as " \
          "existing team #{existing.name.inspect}"
        )
      end
    end

    # The shared mapping machinery for matches: look up the persisted identifier
    # first; on a miss, yield to build the record inside the caller's transaction,
    # then record the mapping. A unique violation means another writer won that
    # race, so the winner is re-read and reused.
    def mapped(kind, external_id)
      identifier = find_identifier(kind, external_id)
      return Resolution.success(target_of(identifier, kind), created: false) if identifier

      record = yield
      persist_identifier(kind, external_id, record)
      Resolution.success(record, created: true)
    rescue ActiveRecord::RecordNotUnique
      recover_from_race(kind, external_id)
    rescue InvalidMatch => e
      Resolution.failure(e.message)
    end

    # A concurrent writer committed the same mapping (or the same canonical row)
    # between our lookup and our insert. PostgreSQL has aborted the current
    # statement, and inside a transaction the transaction is already failed, so
    # the re-read runs in a savepoint. Only `RecordNotUnique` is recovered; every
    # other database error is a real failure and is never masked.
    # `canonical:` lets a caller re-find a record that won on its own unique index
    # (a name or normalized_name) rather than on the mapping index, which is what
    # happens when two writers create the same competition or team at once.
    def recover_from_race(kind, external_id, &canonical)
      identifier = ActiveRecord::Base.transaction(requires_new: true) do
        find_identifier(kind, external_id) || (canonical && canonical.call.then { |record|
          next nil unless record

          persist_identifier(kind, external_id, record)
          record
        })
      end

      unless identifier
        return Resolution.failure("#{kind} was created concurrently; the import can be retried")
      end

      target = identifier.is_a?(ExternalIdentifier) ? target_of(identifier, kind) : identifier
      Resolution.success(target, created: false)
    end

    # ExternalIdentifier has four explicit nullable associations rather than a
    # polymorphic `target`, by design (each is a real foreign key).
    def target_of(identifier, kind)
      identifier.public_send(kind)
    end

    def persist_identifier(kind, external_id, record)
      ExternalIdentifier.create!(provider: provider, external_id: external_id, kind => record)
    end

    # The partial unique indexes are per target type, so the lookup must constrain
    # the same column. Without it a team id equal to a competition id could match
    # the wrong row, because external_id is only unique within a target type.
    def find_identifier(kind, external_id)
      ExternalIdentifier
        .where(provider: provider, external_id: external_id)
        .where.not("#{kind}_id": nil)
        .first
    end

    # Provider codes are compared case- and whitespace-insensitively: "e0" and
    # " E0 " name one league. The canonical name is derived from that key, so two
    # spellings cannot seed two competitions that the name index would reject.
    def normalize_key(value)
      value.to_s.strip.gsub(/\s+/, ' ').upcase
    end

    def canonical_competition_name(key)
      "#{provider} competition #{key}"
    end

    def canonical_name_matches?(competition, key)
      competition.name.to_s == canonical_competition_name(key)
    end

    def mapping_conflict(kind, external_id, target)
      Resolution.failure(
        "#{kind} mapping conflict: provider id #{external_id.inspect} already points at " \
        "#{target.class.name} ##{target.id}"
      )
    end

    def find_canonical_team(display)
      Team.find_by(normalized_name: Team.normalize(display))
    end

    # Only case and whitespace variants of one spelling may adopt an existing
    # canonical team. A materially different name that happens to normalise the
    # same is an operator decision, not something to guess at.
    def meaningful_difference?(existing_name, attempted)
      existing_name.to_s.strip.casecmp?(attempted.to_s.strip) == false
    end

    def team_collision_message(existing, attempted)
      "team name collision: #{attempted.inspect} has the same canonical identity as " \
        "existing team #{existing.name.inspect}; map it explicitly instead of merging"
    end

    # The provider's natural key identifies a fixture within a season, not across
    # seasons: the same division, date and teams recur every year. Prefixing the
    # canonical competition and season makes the stored identity unambiguous, so
    # importing 2025/26 cannot resolve to a 2024/25 match.
    def match_external_id(row, competition, season)
      "#{competition.id}:#{season.id}:#{row.provider_key}"
    end

    def build_match(row, competition:, season:, home_team:, away_team:)
      match = Match.new(
        competition: competition,
        season: season,
        home_team: home_team,
        away_team: away_team,
        kickoff_at: row.kickoff_at,
        status: row.status,
        home_score: row.home_score,
        away_score: row.away_score
      )

      unless match.valid?
        raise InvalidMatch, match.errors.full_messages.to_sentence
      end

      match.save!
      match
    end

    # A row whose values the Match model rejects. Reported as a row-level error.
    class InvalidMatch < StandardError; end

    def attach(resolution, **context)
      return resolution if resolution.success?

      Resolution.failure(resolution.error, **context)
    end
  end
end
