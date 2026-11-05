# The recurring daily synchronization schedule — the single source of truth.
#
# WHY THIS FILE EXISTS RATHER THAN A sidekiq.yml `:schedule:` BLOCK
# ----------------------------------------------------------------
# sidekiq-cron loads a static schedule at boot by re-creating each entry under its
# name. That is correct for a first start, but it silently OVERWRITES an operator's
# hand-edited entry in the Sidekiq UI on the next deploy, and it offers no way to
# run the registration idempotently from outside the worker process (a rake task,
# a spec, a verification step). Keeping the schedule in one Ruby constant means
# the worker, the tests and the status endpoint all read the *same* definition, so
# the endpoint cannot advertise a schedule the worker is not running.
#
# All times are UTC and stated explicitly. The application is configured with
# `config.time_zone = "UTC"`; stating it here as well means the schedule does not
# silently shift if a deployment changes the process TZ (a container inheriting a
# host TZ is the classic way a 03:30 job becomes 04:30 and then 02:30 after DST).
#
# WHY THESE TIMES
# ---------------
# football-data.co.uk publishes its season file in UK morning/evening batches and
# final scores appears on the same day, usually within a few hours of full time.
#
#   03:30 UTC — fixtures. Overnight in the UK and Europe: the previous day's file
#               is final, and the next day's fixtures are published. This is also
#               the quietest hour for the provider, which matters because the
#               source is free and rate-limited.
#   06:00 UTC — results. Two and a half hours after the fixture refresh, and after
#               the previous evening's matches have been in the file for hours. It
#               runs late enough that `ResultSynchronizer.publication_delay`
#               (default 60 minutes) is satisfied even for a late kickoff, so the
#               run does not re-import a file that still reads "scheduled" and
#               report a misleading success with zero results.
#
# The two are 2.5 hours apart so a slow fixture refresh is finished before the
# result import starts. They are not required to be sequential — the ledger's
# per-kind partial unique index already prevents overlap within a kind — but
# spacing them keeps provider requests spread out.
module SidekiqCronSchedule
  TIMEZONE = 'UTC'.freeze

  # Keyed by SYNCHRONIZATION KIND — the same value the ledger stores in
  # sync_runs.kind and the status endpoint reports — so a caller holding a kind
  # never has to translate it into an entry name.
  #
  # `name` is the stable sidekiq-cron entry name. Keeping it stable is what makes
  # re-registration idempotent: sidekiq-cron upserts by name, so a restart updates
  # the existing entry instead of creating a second one.
  ENTRIES = {
    'fixtures' => {
      name: 'sync_fixtures',
      cron: '30 3 * * *',
      class: 'SyncFixturesJob',
      description: 'Daily fixture synchronization (new fixtures, reschedules, postponements)'
    },
    'results' => {
      name: 'sync_results',
      cron: '0 6 * * *',
      class: 'SyncResultsJob',
      description: 'Daily completed-result synchronization and reconciliation'
    },
    # ESPN upcoming-fixture discovery.
    #
    # Added because the football-data CSV carries only played matches, and the
    # ESPN backfill was previously an operator-run rake task. Whatever dates
    # nobody typed simply did not exist, which is how the Premier League grew a
    # 26-day hole while every individual run reported success.
    #
    # 04:15 UTC: after the 03:30 CSV refresh and before the 06:00 result import,
    # so the same day's fixture list is complete before results are reconciled.
    'espn_discovery' => {
      name: 'sync_espn_discovery',
      cron: '15 4 * * *',
      class: 'SyncEspnDiscoveryJob',
      description: 'Daily ESPN fixture discovery across a rolling window, all verified leagues'
    },
    # API-Football live polling.
    #
    # Limited to the hours a Premier League match can plausibly be in progress
    # (12:00-22:55 UTC covers 12:30 Saturday kickoffs through a 20:15 kickoff
    # finishing near 22:05). Outside that window the job does not run at all,
    # which is what makes a 5-minute interval affordable on a 100-request plan.
    # The synchronizer skips the request entirely when no live fixtures are
    # returned, so a poll during a dead hour costs one request and nothing more.
    'live' => {
      name: 'api_football_live',
      cron: '*/5 12-22 * * *',
      class: 'ApiFootballLiveSyncJob',
      description: 'Live fixture polling every 5 minutes during match hours'
    },
    # Per-match result checking.
    #
    # The dispatcher is a DATABASE QUERY, not a provider request: it selects the
    # matches that are due and enqueues one `MatchResultCheckJob` each. Running it
    # every five minutes therefore costs no ESPN quota, and a provider outage
    # cannot stop the queue from being filled.
    #
    # Every five minutes, all day: a match can finish at any hour, and the
    # dispatcher's own eligibility rules (2h15m buffer, 24h window) decide what is
    # actually due. There is no hour restriction to get wrong.
    #
    # NOT ACTIVE. This entry is defined so the schedule is reviewable and
    # testable, but `SidekiqCronSchedule.register!` is only called by the worker at
    # boot, and the worker is not running. Activating it is a separate, explicit
    # decision (handout §24).
    'result_check' => {
      name: 'match_result_dispatch',
      cron: '*/5 * * * *',
      class: 'MatchResultDispatchJob',
      description: 'Per-match ESPN result checking: enqueue one check per due match'
    }
  }.freeze

  # WHICH ENTRIES A WORKER REGISTERS AT BOOT.
  #
  # Before this existed, starting the worker registered all five entries —
  # including four that write to the database and call providers. That made
  # "activate the result dispatcher" impossible without also activating fixture
  # sync, result sync, ESPN discovery and live polling.
  #
  #   disabled              register nothing (DEFAULT)
  #   result_dispatch_only  register only `match_result_dispatch`
  #   all                   register all five
  #
  # THE DEFAULT IS `disabled`, and an UNKNOWN value also resolves to `disabled`.
  # A typo in the environment must fail towards "nothing runs", never towards
  # "every job runs". `mode_warning` names the bad value so the mistake is visible
  # in the boot log instead of being silently absorbed.
  MODES = %i[disabled result_dispatch_only all].freeze
  MODE_ENV = 'SIDEKIQ_CRON_MODE'.freeze
  DEFAULT_MODE = :disabled

  # The entries each mode registers, by sidekiq-cron name.
  MODE_ENTRIES = {
    disabled: [].freeze,
    result_dispatch_only: %w[match_result_dispatch].freeze,
    all: nil # nil means "every entry"
  }.freeze

  # The sidekiq-cron entry names, in definition order.
  def self.names
    ENTRIES.values.map { |entry| entry[:name] }
  end

  # The configured mode, always one of MODES.
  def self.mode
    raw = ENV[MODE_ENV].to_s.strip.downcase
    return DEFAULT_MODE if raw.empty?

    candidate = raw.to_sym
    MODES.include?(candidate) ? candidate : DEFAULT_MODE
  end

  # A human-readable complaint when the configured value is not a known mode, or
  # nil when it is fine. The worker logs this at boot.
  def self.mode_warning
    raw = ENV[MODE_ENV].to_s.strip
    return nil if raw.empty?
    return nil if MODES.include?(raw.downcase.to_sym)

    "unknown #{MODE_ENV}=#{raw.inspect}; expected one of #{MODES.join(', ')}. " \
      "Falling back to #{DEFAULT_MODE} — no recurring jobs will be registered."
  end

  # The entry names the current mode registers.
  def self.entries_for_mode
    selected = MODE_ENTRIES.fetch(mode)
    selected.nil? ? names : selected
  end

  # Builds sidekiq-cron job definitions. `args` is empty on purpose: the job's
  # default trigger is 'schedule', which is what an operator should see in the
  # ledger for an automated run.
  def self.definitions
    ENTRIES.map do |_kind, entry|
      {
        'name' => entry[:name],
        'cron' => entry[:cron],
        'class' => entry[:class],
        'description' => entry[:description],
        'args' => [],
        # The timezone is part of the cron string sidekiq-cron stores. Setting it
        # here is the documented way to make an entry independent of process TZ.
        'active_job' => false,
        'queue' => 'sync'
      }.tap { |hash| hash['cron'] = "#{hash['cron']} #{TIMEZONE}" }
    end
  end

  # Registers the entries the current MODE selects, replacing any entry of the
  # same name and leaving unrelated entries alone. Returns the names registered.
  #
  # Safe to call repeatedly: sidekiq-cron upserts by name, so a second call
  # updates rather than duplicating. This is what the worker does at boot, and
  # what any verification step should do rather than trusting a side effect of
  # startup.
  #
  # It does NOT remove entries the mode excludes. An operator's hand-added entry
  # must survive, and removing entries is a destructive act that belongs to an
  # explicit command, not to a boot hook.
  def self.register!
    selected = entries_for_mode

    definitions.select { |definition| selected.include?(definition['name']) }.map do |definition|
      job = Sidekiq::Cron::Job.new(definition)
      unless job.save
        raise "could not register #{definition['name']}: #{Array(job.errors).join(', ')}"
      end
      definition['name']
    end
  end
end
