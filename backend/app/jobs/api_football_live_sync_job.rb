# Live fixture polling, run by the `api_football_live` cron entry.
#
# WHY EVERY TWO MINUTES AND NOT EVERY ONE
# ---------------------------------------
# The provider updates live fixtures roughly every minute, but this account has
# 100 requests per day. One poll returns EVERY live fixture across every league,
# so the cost is per-poll, not per-match:
#
#   1 poll/min over a 6-hour window = 360 requests  -> quota exhausted by lunch
#   1 poll/2min over a 6-hour window = 180 requests -> still exceeds the quota
#   1 poll/5min over a 3-hour window =  36 requests -> leaves room for the daily
#                                                      fixture and result imports
#
# The practical ceiling on the free plan is a poll every 5 minutes during a
# 3-hour match window, i.e. roughly 36 requests per match day. Anything faster
# starves the daily syncs, which are the source of truth. The schedule is
# therefore `*/5` limited to a realistic kickoff window (see
# config/sidekiq_cron_schedule.rb); outside those hours it does not run at all.
#
# The job also refuses to poll when the ledger shows another run still open, so
# a slow provider response cannot stack requests.
class ApiFootballLiveSyncJob < ApplicationJob
  include ScheduledSynchronization

  def self.synchronizer_class
    Sync::ApiFootballLiveSynchronizer
  end

  def synchronizer_class
    self.class.synchronizer_class
  end
end
