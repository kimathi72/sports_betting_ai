# A football team, identified independently of any competition or season.
#
# Identity policy: `name` stores the source's display name verbatim, while
# `normalized_name` is a deterministic, comparison-friendly projection used as
# the unique identity. Two sources spelling a team differently by case, spacing
# or diacritics collapse onto the same canonical row.
#
# Deliberately NOT implemented here: fuzzy matching, aliases, or abbreviations.
# Those belong to the provider-import phase, where real source variation can be
# observed and tested rather than guessed at.
class Team < ApplicationRecord
  has_many :home_matches, class_name: "Match",
                          foreign_key: :home_team_id,
                          inverse_of: :home_team,
                          dependent: :restrict_with_error
  has_many :away_matches, class_name: "Match",
                          foreign_key: :away_team_id,
                          inverse_of: :away_team,
                          dependent: :restrict_with_error

  # `normalized_name` is kept in step with `name` on every assignment so it is
  # already correct on an unsaved record, not only after validation.
  before_validation :assign_normalized_name

  validates :name, presence: true
  validates :normalized_name, presence: true, uniqueness: true

  # Deterministic normalization applied to every team name.
  #
  # Steps, in order: fold diacritics to ASCII, downcase, collapse runs of
  # whitespace, trim. The result is stable across runs and platforms, which is
  # what makes it safe to use as a unique key.
  def self.normalize(name)
    return nil if name.nil?

    ActiveSupport::Inflector.transliterate(name.to_s)
                          .downcase
                          .gsub(/\s+/, " ")
                          .strip
  end

  # Mirrors the stored value, falling back to deriving it from `name` for
  # unsaved records so callers never see a nil normalization mid-build.
  def normalized_name
    super.presence || self.class.normalize(name)
  end

  private

  def assign_normalized_name
    return if name.blank?

    self[:normalized_name] = self.class.normalize(name)
  end
end
