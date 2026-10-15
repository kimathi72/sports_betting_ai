# Maps a provider's identifier for a football entity onto this platform's
# canonical record. Providers disagree about identifiers — one calls the Premier
# League "EPL", another "1" — so provider identity is kept out of the canonical
# tables and centralised here. This is what makes future imports idempotent and
# deduplicable.
#
# Design: explicit nullable foreign keys, one per entity type, rather than a
# Rails polymorphic `*_type`/`*_id` pair. See the migration and docs/roadmap.md
# for the trade-off. In short: a polymorphic id cannot carry a database foreign
# key, so a polymorphic row could point at a record that does not exist or at a
# class that is not a football entity. Here every target is a real FK and the
# database additionally requires exactly one target per row.
#
# Limitations of this design (documented deliberately):
#   - adding a new mappable entity type requires a migration (new nullable
#     column and a new partial unique index), whereas a polymorphic design would
#     need only application code;
#   - the "exactly one target" rule is expressed twice, in the model validation
#     and in the PostgreSQL check constraint, so the two must be kept in step.
class ExternalIdentifier < ApplicationRecord
  # The entity types an external identifier may map to. The column name for each
  # type is derived as "#{type}_id", which is what the check constraint counts.
  TARGETS = %i[competition season team match].freeze

  belongs_to :competition, optional: true
  belongs_to :season, optional: true
  belongs_to :team, optional: true
  belongs_to :match, optional: true

  validates :provider, presence: true
  validates :external_id, presence: true
  validate :exactly_one_target

  # Uniqueness within the provider and the entity type. The scope is the
  # provider plus the target type, NOT the specific row the identifier points
  # at: a provider cannot give the same id to two different teams. The database
  # backs this with four partial unique indexes (one per target type); the
  # validation gives callers a friendly error instead of a raw constraint
  # violation. Each `conditions` clause mirrors the matching index predicate.
  validates :external_id,
            uniqueness: {
              scope: :provider,
              conditions: -> { where.not(competition_id: nil) },
            },
            if: -> { competition_id.present? }
  validates :external_id,
            uniqueness: {
              scope: :provider,
              conditions: -> { where.not(season_id: nil) },
            },
            if: -> { season_id.present? }
  validates :external_id,
            uniqueness: {
              scope: :provider,
              conditions: -> { where.not(team_id: nil) },
            },
            if: -> { team_id.present? }
  validates :external_id,
            uniqueness: {
              scope: :provider,
              conditions: -> { where.not(match_id: nil) },
            },
            if: -> { match_id.present? }

  private

  def exactly_one_target
    present = TARGETS.select { |target| public_send("#{target}_id").present? }

    return if present.size == 1

    errors.add(:base, "must reference exactly one target (competition, season, team or match)")
  end
end
