require 'rails_helper'

# The readiness endpoint delegates the actual connectivity question to this
# small service so the failure path can be tested deterministically without
# touching the shared PostgreSQL container. The service must never let a raw
# driver exception escape; it reports a typed Result either way.
RSpec.describe DatabaseHealthCheck do
  describe '.call' do
    context 'when the database answers' do
      it 'returns a healthy result' do
        result = described_class.call

        expect(result).to be_available
        expect(result.status).to eq('ok')
      end
    end

    context 'when the connection cannot be established' do
      before do
        allow(ActiveRecord::Base).to receive(:connection)
          .and_raise(ActiveRecord::ConnectionNotEstablished, 'simulated outage')
      end

      it 'returns an unavailable result instead of raising' do
        result = described_class.call

        expect(result).not_to be_available
        expect(result.status).to eq('unavailable')
      end

      it 'does not expose the driver error message' do
        result = described_class.call

        expect(result.status).not_to match(/simulated outage|ConnectionNotEstablished/i)
      end
    end

    context 'when the query itself fails' do
      before do
        allow(ActiveRecord::Base).to receive(:connection).and_raise(
          ActiveRecord::StatementInvalid, 'PG::UndefinedTable: relation "x"'
        )
      end

      it 'still returns an unavailable result' do
        expect(described_class.call.status).to eq('unavailable')
      end
    end
  end

  describe 'Result' do
    it 'exposes available/unavailable factory helpers' do
      expect(described_class::Result.available).to be_available
      expect(described_class::Result.unavailable).not_to be_available
    end
  end
end
