# ActiveJob test helpers (`perform_enqueued_jobs`, `have_enqueued_job`) are only
# useful to specs that exercise the queue, so they are included for job specs
# rather than globally. RSpec infers type `:job` from `spec/jobs/*_spec.rb`.
RSpec.configure do |config|
  config.include ActiveJob::TestHelper, type: :job
end
