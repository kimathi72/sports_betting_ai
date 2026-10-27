module Import
  # The outcome of resolving one provider identifier (or one whole row) to
  # canonical records.
  #
  # Resolution failures are ordinary data, not exceptions: a provider id that
  # already points somewhere else, a blank season label or an unsupported status
  # are all things the importer must report per row rather than blow up on. The
  # exception is `RecordNotUnique`, which the resolver recovers from and never
  # surfaces.
  #
  # `created_record?` describes the RECORD this resolution targeted (a newly
  # inserted Competition/Season/Team/Match). It is not the row-level outcome
  # that Import::Result counts; a row can reuse every reference and still create
  # a Match.
  class Resolution
    attr_reader :record, :error, :competition, :season, :home_team, :away_team, :match

    def initialize(record: nil, error: nil, created: false, competition: nil, season: nil,
                   home_team: nil, away_team: nil, match: nil)
      @record = record
      @match = match || (record if record.is_a?(Match))
      @error = error
      @created = created
      @competition = competition
      @season = season
      @home_team = home_team
      @away_team = away_team
      freeze
    end

    def self.success(record, created: false, **context)
      new(record: record, created: created, **context)
    end

    def self.failure(message, **context)
      new(error: message.to_s, **context)
    end

    def success?
      @error.nil?
    end

    def failure?
      !success?
    end

    def created_record?
      @created
    end
  end
end
