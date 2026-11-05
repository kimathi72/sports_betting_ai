require "rails_helper"

# Which recurring jobs a worker registers at boot.
#
# WHY THIS EXISTS
# ---------------
# Starting the worker used to register ALL five entries, including four that write
# to the database and call providers. That made "activate the result dispatcher"
# impossible without also activating fixture sync, result sync, ESPN discovery and
# live polling. The mode makes the choice explicit and fail-safe.
#
# THE DEFAULT IS `disabled`. A missing or unreadable configuration must never
# activate anything: the failure mode of a typo must be "nothing runs", not "every
# job runs".
RSpec.describe SidekiqCronSchedule, "registration mode" do
  # The suite's support file registers the FULL schedule for the other specs, so
  # these examples must start from an empty Redis and put it back afterwards —
  # otherwise they would silently unregister the schedule the rest of the suite
  # asserts against.
  around do |example|
    previous_mode = ENV["SIDEKIQ_CRON_MODE"]
    SidekiqCronSchedule.names.each { |name| Sidekiq::Cron::Job.destroy(name) }
    example.run
  ensure
    SidekiqCronSchedule.names.each { |name| Sidekiq::Cron::Job.destroy(name) }
    ENV["SIDEKIQ_CRON_MODE"] = previous_mode
    # Restore the suite-wide schedule the support file established.
    ENV["SIDEKIQ_CRON_MODE"] = "all"
    SidekiqCronSchedule.register!
    if previous_mode.nil?
      ENV.delete("SIDEKIQ_CRON_MODE")
    else
      ENV["SIDEKIQ_CRON_MODE"] = previous_mode
    end
  end

  def registered_names
    Sidekiq::Cron::Job.all.map(&:name).sort
  end

  describe "mode parsing" do
    it "defaults to disabled when the variable is absent" do
      ENV.delete("SIDEKIQ_CRON_MODE")

      expect(described_class.mode).to eq(:disabled)
    end

    it "defaults to disabled when the variable is blank" do
      ENV["SIDEKIQ_CRON_MODE"] = "  "

      expect(described_class.mode).to eq(:disabled)
    end

    it "accepts result_dispatch_only" do
      ENV["SIDEKIQ_CRON_MODE"] = "result_dispatch_only"

      expect(described_class.mode).to eq(:result_dispatch_only)
    end

    it "accepts all" do
      ENV["SIDEKIQ_CRON_MODE"] = "all"

      expect(described_class.mode).to eq(:all)
    end

    it "is case and whitespace insensitive" do
      ENV["SIDEKIQ_CRON_MODE"] = "  RESULT_DISPATCH_ONLY "

      expect(described_class.mode).to eq(:result_dispatch_only)
    end

    it "fails safe to disabled on an unknown value" do
      ENV["SIDEKIQ_CRON_MODE"] = "everything"

      expect(described_class.mode).to eq(:disabled)
    end

    it "reports an unknown value rather than silently accepting it" do
      ENV["SIDEKIQ_CRON_MODE"] = "everything"

      expect(described_class.mode_warning).to match(/everything/)
    end
  end

  describe "registration" do
    it "registers nothing in disabled mode" do
      ENV["SIDEKIQ_CRON_MODE"] = "disabled"

      expect(described_class.register!).to eq([])
      expect(registered_names).to be_empty
    end

    it "registers nothing when the variable is missing" do
      ENV.delete("SIDEKIQ_CRON_MODE")

      expect(described_class.register!).to eq([])
      expect(registered_names).to be_empty
    end

    it "registers only the dispatcher in result_dispatch_only mode" do
      ENV["SIDEKIQ_CRON_MODE"] = "result_dispatch_only"

      expect(described_class.register!).to eq(["match_result_dispatch"])
      expect(registered_names).to eq(["match_result_dispatch"])
    end

    it "leaves the four other jobs unregistered in isolated mode" do
      ENV["SIDEKIQ_CRON_MODE"] = "result_dispatch_only"

      described_class.register!

      %w[sync_fixtures sync_results sync_espn_discovery api_football_live].each do |name|
        expect(Sidekiq::Cron::Job.find(name)).to be_nil
      end
    end

    it "keeps the dispatcher on its five-minute schedule" do
      ENV["SIDEKIQ_CRON_MODE"] = "result_dispatch_only"

      described_class.register!

      job = Sidekiq::Cron::Job.find("match_result_dispatch")
      expect(job.cron).to match(%r{^\*/5 \* \* \* \*})
      expect(job.klass).to eq("MatchResultDispatchJob")
    end

    it "registers all five in all mode" do
      ENV["SIDEKIQ_CRON_MODE"] = "all"

      expect(described_class.register!.sort).to eq(
        %w[api_football_live match_result_dispatch sync_espn_discovery
           sync_fixtures sync_results]
      )
      expect(registered_names.size).to eq(5)
    end

    it "registers nothing on an unknown mode" do
      ENV["SIDEKIQ_CRON_MODE"] = "everything"

      expect(described_class.register!).to eq([])
      expect(registered_names).to be_empty
    end

    it "does not duplicate entries when called repeatedly" do
      ENV["SIDEKIQ_CRON_MODE"] = "result_dispatch_only"

      described_class.register!
      described_class.register!
      described_class.register!

      expect(registered_names).to eq(["match_result_dispatch"])
    end

    it "does not remove entries it did not register" do
      # An operator's hand-added entry must survive a registration pass.
      Sidekiq::Cron::Job.create(name: "operator_manual", cron: "0 1 * * *",
                                class: "SyncFixturesJob")
      ENV["SIDEKIQ_CRON_MODE"] = "result_dispatch_only"

      described_class.register!

      expect(Sidekiq::Cron::Job.find("operator_manual")).not_to be_nil
    ensure
      Sidekiq::Cron::Job.destroy("operator_manual")
    end
  end

  describe "definitions" do
    it "still describes all five entries regardless of mode" do
      # The mode decides what is REGISTERED, not what is configured. A definition
      # list that shrank with the mode would make the schedule unreviewable.
      ENV["SIDEKIQ_CRON_MODE"] = "disabled"

      expect(described_class.definitions.size).to eq(5)
    end
  end
end
