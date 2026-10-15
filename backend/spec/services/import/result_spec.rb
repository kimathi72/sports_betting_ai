require 'rails_helper'

# Import::Result is the single, predictable value object an import run returns.
#
# Semantics of the counts (deliberately fixed and documented so callers and tests
# never disagree):
#   - `input`     — number of raw source rows read from the file, including header
#                   is excluded; this is the row count the reader produced.
#   - `processed` — rows that passed parsing and were handed to resolution.
#   - `created`   — canonical Match records newly persisted by this run.
#   - `reused`    — matches already present (by verified mapping) and not re-created.
#   - `rejected`  — rows that failed parsing or resolution and were not persisted.
#
# Invariant: processed + rejected == input, and created + reused == processed.
RSpec.describe Import::Result do
  describe 'a successful result' do
    subject(:result) do
      described_class.new(
        success: true,
        input: 7,
        processed: 7,
        created: 7,
        reused: 0,
        rejected: 0,
        errors: []
      )
    end

    it 'reports success' do
      expect(result).to be_success
      expect(result).not_to be_failure
    end

    it 'exposes the counts' do
      expect(result.input).to eq(7)
      expect(result.processed).to eq(7)
      expect(result.created).to eq(7)
      expect(result.reused).to eq(0)
      expect(result.rejected).to eq(0)
    end

    it 'has no errors' do
      expect(result.errors).to eq([])
    end
  end

  describe 'a failed result' do
    subject(:result) do
      described_class.new(
        success: false,
        input: 7,
        processed: 0,
        created: 0,
        reused: 0,
        rejected: 7,
        errors: ['row 2: date/time is not a valid timestamp: nope 15:00']
      )
    end

    it 'reports failure' do
      expect(result).to be_failure
      expect(result).not_to be_success
    end

    it 'carries actionable row-level errors' do
      expect(result.errors).to contain_exactly(
        a_string_matching(/row 2: .*date/i)
      )
    end
  end

  describe 'defaults' do
    it 'defaults every count to zero and success to false' do
      result = described_class.new

      expect(result).to be_failure
      expect(result.input).to eq(0)
      expect(result.processed).to eq(0)
      expect(result.created).to eq(0)
      expect(result.reused).to eq(0)
      expect(result.rejected).to eq(0)
      expect(result.errors).to eq([])
    end
  end

  describe '#errors' do
    it 'is always an array, even when constructed without one' do
      expect(described_class.new.errors).to eq([])
    end
  end

  describe 'error safety' do
    it 'does not expose raw SQL or driver messages' do
      # The importer must translate persistence failures into safe messages.
      # This guards against ever leaking a PostgreSQL error string verbatim.
      safe = described_class.failure(
        input: 1,
        rejected: 1,
        errors: ['row 1: could not be persisted']
      )

      safe.errors.each do |message|
        expect(message).not_to match(/PG::|ActiveRecord::|SQL|stack/i)
      end
    end
  end

  describe '.success' do
    it 'builds a successful result with the given counts' do
      result = described_class.success(input: 3, processed: 3, created: 2, reused: 1)

      expect(result).to be_success
      expect(result.created).to eq(2)
      expect(result.reused).to eq(1)
      expect(result.rejected).to eq(0)
    end
  end

  describe '.failure' do
    it 'builds a failed result and carries the errors' do
      result = described_class.failure(input: 2, rejected: 2, errors: ['row 1: boom'])

      expect(result).to be_failure
      expect(result.errors).to eq(['row 1: boom'])
      expect(result.created).to eq(0)
    end
  end
end
