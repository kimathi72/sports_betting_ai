# A period of competition within one Competition.
#
# Internal representation: `name` is the platform's own label for the season
# (e.g. "2024/25"), unique within its competition. Provider-specific season
# labels are mapped through ExternalIdentifier rather than stored here, because
# providers format them inconsistently.
class Season < ApplicationRecord
  belongs_to :competition
  has_many :matches, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: { scope: :competition_id }
  validate :start_date_not_after_end_date

  private

  def start_date_not_after_end_date
    return if start_date.blank? || end_date.blank?
    return if start_date <= end_date

    errors.add(:start_date, "must not be after the end date")
  end
end
