require "rails_helper"

# Arguments must survive the enqueue round-trip.
#
# THE INCIDENT (2026-11-05)
# -------------------------
# The first live Sidekiq run enqueued four `MatchResultCheckJob`s and every one
# died with:
#
#   ArgumentError: wrong number of arguments (given 0, expected 1..2)
#   app/jobs/match_result_check_job.rb:68:in `perform'
#
# The Sidekiq payload showed `"arguments": []`. The job's constructor accepted the
# perform arguments via `*_args` and then called `super()` with NO arguments, so
# ActiveJob's `@arguments` stayed empty and nothing was serialised.
#
# WHY THE EXISTING SPECS MISSED IT
# --------------------------------
# Every job spec calls `perform` directly on an instance. That never serialises
# arguments, so a constructor that swallows them looks perfect. These specs go
# through the real ActiveJob serialisation path instead.
RSpec.describe "job argument round-trip" do
  # The serialised payload ActiveJob would hand to Sidekiq.
  def serialized_arguments(job_class, *args)
    job = job_class.new(*args)
    job.serialize["arguments"]
  end

  it "serialises MatchResultCheckJob's arguments" do
    expect(serialized_arguments(MatchResultCheckJob, 42, 3)).to eq([42, 3])
  end

  it "serialises MatchResultDispatchJob's (empty) arguments" do
    expect(serialized_arguments(MatchResultDispatchJob)).to eq([])
  end

  it "reconstructs MatchResultCheckJob with the arguments it was given" do
    payload = MatchResultCheckJob.new(42, 3).serialize

    rebuilt = ActiveJob::Base.execute(payload.merge("job_id" => "test"))

    # `execute` runs `perform`; a swallowed argument raises ArgumentError before
    # this line. The match does not exist, so the job records "match not found"
    # and returns — which is the correct, non-raising outcome.
    expect(rebuilt).to eq("ineligible")
  end

  it "keeps the collaborators out of the serialised payload" do
    # A client or synchronizer passed for a test must never be serialised: it is
    # not a perform argument, and Sidekiq cannot marshal it.
    payload = MatchResultCheckJob.new(42, 1, client: :fake).serialize

    expect(payload["arguments"]).to eq([42, 1])
  end
end
