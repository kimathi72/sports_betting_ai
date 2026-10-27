require 'rails_helper'

# Import::Result is the single, predictable value object an import run returns.
#
# COUNTER SEMANTICS (each source row lands in exactly one row-outcome counter):
#   - `input`     — data rows the reader produced (header excluded, blank lines
#                   already dropped). The denominator for every invariant.
#   - `processed` — rows that were validated, resolved and persisted. It is
#                   always created + updated + skipped.
#   - `created`   — rows persisted as a NEW Match.
#   - `updated`   — rows that changed an EXISTING Match (e.g. a scheduled fixture
#                   receiving its first result).
#   - `skipped`   — rows that matched an existing Match and changed nothing, e.g.
#                   re-importing an identical completed result. This is a ROW
#                   outcome. It is deliberately NOT named `reused`: reusing a
#                   canonical Team/Competition happens inside a row that still
#                   created/updated/skipped a Match, so "record reused" and
#                   "row skipped" are distinct concepts and must not share a
#                   counter.
#   - `rejected`  — rows that failed validation, resolution or persistence.
#
# Invariants (enforced by the constructor, not merely documented):
#   created + updated + skipped + rejected == input
#   processed                             == created + updated + skipped
#   a successful result has rejected == 0
#   a failed result has rejected  >  0 and wrote nothing
#
# Errors are structured hashes so callers can map a failure to the row that
# caused it. Messages are plain text: SQL, driver details, credentials and
# stack traces never reach here.
RSpec.describe Import::Result do
  let(:row_error) do
    Import::Result.error(index: 1, message: 'date/time is not a valid timestamp: nope 15:00')
  end

  describe 'a successful result' do
    subject(:result) do
      described_class.success(input: 7, created: 5, updated: 1, skipped: 1)
    end

    it 'reports success' do
      expect(result).to be_success
      expect(result).not_to be_failure
    end

    it 'exposes the counters' do
      expect(result.input).to eq(7)
      expect(result.processed).to eq(7)
      expect(result.created).to eq(5)
      expect(result.updated).to eq(1)
      expect(result.skipped).to eq(1)
      expect(result.rejected).to eq(0)
    end

    it 'derives processed from the row outcomes' do
      expect(result.processed).to eq(result.created + result.updated + result.skipped)
    end

    it 'has no errors' do
      expect(result.errors).to eq([])
    end
  end

  describe 'a failed result' do
    subject(:result) do
      described_class.failure(input: 7, rejected: 7, errors: [row_error])
    end

    it 'reports failure' do
      expect(result).to be_failure
      expect(result).not_to be_success
    end

    it 'carries structured, row-indexed errors' do
      expect(result.errors.length).to eq(1)
      expect(result.errors.first).to include(index: 1)
      expect(result.errors.first[:message]).to match(/date/i)
    end

    it 'reports each error with its human-readable position' do
      expect(result.errors.first[:row]).to eq(2)
    end

    it 'claims nothing was written' do
      # Whole-batch atomicity: a failed run rolls back, so no counter may
      # suggest that rows were created, updated or skipped.
      expect(result.created).to eq(0)
      expect(result.updated).to eq(0)
      expect(result.skipped).to eq(0)
    end
  end

  describe 'the error format' do
    it 'exposes the zero-based index and the one-based row number' do
      expect(row_error).to include(index: 1, row: 2)
    end

    it 'renders a single-line summary usable in a log or CLI' do
      expect(Import::Result.format_error(row_error)).to eq(
        'row 2: date/time is not a valid timestamp: nope 15:00'
      )
    end
  end

  describe 'defaults' do
    it 'defaults every counter to zero and success to false' do
      result = described_class.new

      expect(result).to be_failure
      expect(result.input).to eq(0)
      expect(result.processed).to eq(0)
      expect(result.created).to eq(0)
      expect(result.updated).to eq(0)
      expect(result.skipped).to eq(0)
      expect(result.rejected).to eq(0)
      expect(result.errors).to eq([])
    end
  end

  describe '#errors' do
    it 'is always a frozen array' do
      expect(described_class.new.errors).to eq([])
      expect(described_class.new.errors).to be_frozen
    end
  end

  describe 'invariant enforcement' do
    it 'rejects counters that do not account for every input row' do
      expect {
        described_class.success(input: 7, created: 5, rejected: 0)
      }.to raise_error(Import::Result::InvalidCounters, /account for/)
    end

    it 'rejects a result whose processed count disagrees with its row outcomes' do
      expect {
        described_class.success(input: 3, created: 3, rejected: 0, processed: 9)
      }.to raise_error(Import::Result::InvalidCounters, /processed/)
    end

    it 'rejects a successful result that also claims rejections' do
      expect {
        described_class.success(input: 2, created: 1, rejected: 1)
      }.to raise_error(Import::Result::InvalidCounters, /reject/i)
    end

    it 'rejects a failed result that claims no rejected rows' do
      expect {
        described_class.failure(input: 1)
      }.to raise_error(Import::Result::InvalidCounters, /reject/i)
    end

    it 'rejects a failed result that claims rows were written' do
      expect {
        described_class.failure(input: 2, created: 1, rejected: 1)
      }.to raise_error(Import::Result::InvalidCounters, /rolled back|created|updated|skipped/i)
    end

    it 'rejects a failure whose rejected count exceeds the input' do
      expect {
        described_class.failure(input: 1, rejected: 9)
      }.to raise_error(Import::Result::InvalidCounters, /account for/)
    end

    it 'rejects negative counters' do
      expect {
        described_class.success(input: 1, created: -1, rejected: 2)
      }.to raise_error(Import::Result::InvalidCounters, /negative/i)
    end
  end

  describe 'immutability' do
    it 'cannot be mutated after construction' do
      result = described_class.success(input: 1, created: 1)

      expect(result).to be_frozen
      expect { result.instance_variable_set(:@created, 99) }.to raise_error(FrozenError)
    end
  end

  describe 'error safety' do
    it 'does not expose raw SQL or driver messages' do
      safe = described_class.failure(
        input: 1,
        rejected: 1,
        errors: [described_class.error(index: 0, message: 'could not be persisted')]
      )

      expect(described_class.format_error(safe.errors.first)).not_to match(/PG::|ActiveRecord::|SQL|stack/i)
    end
  end

  describe '#summary' do
    it 'renders a concise operator-facing line' do
      result = described_class.success(input: 3, created: 2, skipped: 1)

      expect(result.summary).to eq(
        'imported 3 rows: 2 created, 0 updated, 1 skipped, 0 rejected'
      )
    end

    it 'marks a failed run as failed' do
      result = described_class.failure(input: 2, rejected: 2, errors: [row_error])

      expect(result.summary).to start_with('import failed')
      expect(result.summary).to include('2 rejected')
    end
  end
end
