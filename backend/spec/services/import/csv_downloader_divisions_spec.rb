require 'rails_helper'

# Competition expansion: the downloader's division list is what decides which
# football-data.co.uk files the pipeline can obtain. Every code below was
# verified against the live source (HTTP 200 + a CSV body) before being added, so
# this spec pins the list rather than re-deriving it from the network: a unit test
# that calls out to a free provider is a flaky test, not a correctness check.
RSpec.describe Import::CsvDownloader do
  describe 'supported divisions' do
    it 'covers the major European leagues plus England and Scotland' do
      %w[E0 E1 E2 E3 EC SC0 SC1 SP1 SP2 D1 D2 I1 I2 F1 F2 N1 B1 P1 T1 G1].each do |code|
        expect(described_class::SUPPORTED_DIVISIONS).to include(code)
      end
    end

    it 'labels every supported division with a country and a competition name' do
      described_class::SUPPORTED_DIVISIONS.each do |code|
        country, name = described_class::DIVISION_LABELS.fetch(code)
        expect(country).to be_present
        expect(name).to be_present
      end
    end

    it 'refuses a division it does not know rather than guessing a URL' do
      expect {
        described_class.new(destination_dir: Dir.mktmpdir, division: 'ZZ9')
      }.to raise_error(Import::CsvDownloader::InvalidInput, /unsupported division/i)
    end

    it 'builds the source URL from the season code and division' do
      downloader = described_class.new(destination_dir: Dir.mktmpdir, division: 'SP1')
      expect(downloader.send(:source_url, season: '2024/25'))
        .to eq('https://www.football-data.co.uk/mmz4281/2425/SP1.csv')
    end
  end
end
