# A football competition such as the English Premier League. The top of the
# domain hierarchy: a competition owns its seasons and its matches.
#
# Identity: `name` is the required, unique identity. `code` is an optional
# short label that is unique when present but must not be treated as a stable
# external identifier — provider identity lives in ExternalIdentifier.
class Competition < ApplicationRecord
  has_many :seasons, dependent: :restrict_with_error
  has_many :matches, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: true
  validates :code, uniqueness: true, allow_nil: true
end
