require 'rails_helper'

# The execution contract every background job in this project inherits.
#
# These are deliberately structural assertions: a job that quietly stops being a
# background job (wrong superclass, wrong adapter, ActiveRecord objects smuggled
# into its arguments) is a production incident, not a style preference. Getting
# the contract pinned here means individual job specs only have to test their own
# logic.
RSpec.describe ApplicationJob do
  describe 'inheritance' do
    it 'is an ActiveJob job' do
      expect(described_class.ancestors).to include(ActiveJob::Base)
    end

    it 'routes enqueued jobs through ActiveJob rather than running them inline' do
      # A concrete subclass must be enqueueable, not executed by the caller.
      job_class = Class.new(described_class) do
        def self.name
          'SpecProbeJob'
        end

        def perform(*); end
      end

      expect(ActiveJob::Base.queue_adapter).to be_a(ActiveJob::QueueAdapters::TestAdapter)
      expect { job_class.perform_later('x') }.to have_enqueued_job(job_class).with('x')
    end
  end

  describe 'queue configuration' do
    it 'defaults to the default queue' do
      expect(described_class.new.queue_name).to eq('default')
    end

    it 'is configured to use Sidekiq outside the test environment' do
      # The test adapter is used in specs, so the production wiring is asserted
      # from application.rb itself rather than by booting a worker here.
      source = Rails.root.join('config', 'application.rb').read

      expect(source).to match(/queue_adapter\s*=\s*Rails\.env\.test\?\s*\?\s*:test\s*:\s*:sidekiq/)
    end

    it 'declares the queues its worker consumes' do
      config = YAML.load_file(Rails.root.join('config', 'sidekiq.yml'), aliases: true)

      expect(config[:queues]).to include('default')
    end
  end

  describe 'argument serialisation' do
    it 'round-trips simple identifiers' do
      job = described_class.new('a-path.csv', '2024/25')
      job.arguments = ActiveJob::Arguments.serialize(job.arguments)
      restored = ActiveJob::Arguments.deserialize(job.arguments)

      expect(restored).to eq(['a-path.csv', '2024/25'])
    end

    it 'does not accept records that cannot be serialised' do
      # There is no GlobalID model here, so passing a record must be rejected at
      # enqueue time rather than blowing up in the worker.
      expect {
        Class.new(described_class) do
          def self.name
            'RecordProbeJob'
          end

          def perform(_record); end
        end.perform_later(Object.new)
      }.to raise_error(ActiveJob::SerializationError)
    end
  end
end
