require 'rails_helper'
require 'net/http'

# Downloads are the only place this project talks to the network, so every spec
# here stubs Net::HTTP at the seam the downloader actually uses. No spec may
# reach football-data.co.uk, and no HTTP-stubbing gem is used (the project has
# none, and this is a single seam).
#
# The behaviours under test are the ones that protect the data pipeline:
#   - the URL is derived from validated input, never supplied by a caller
#   - only the official host is contacted, including through redirects
#   - failures are classified so callers can act (retry vs give up)
#   - content is validated as a real CSV before it is promoted into data/raw
#   - a download is atomic and never silently overwrites an existing file
#   - provenance is recorded so an import can be reproduced and audited
RSpec.describe Import::CsvDownloader do
  let(:dest) { Rails.root.join('tmp', 'csv_downloader_spec').to_s }

  before do
    FileUtils.rm_rf(dest)
    FileUtils.mkdir_p(dest)
  end

  after { FileUtils.rm_rf(dest) }

  def downloader(**options)
    described_class.new(destination_dir: dest, **options)
  end

  # A modern file: the required columns plus the optional Time column, which is
  # what the default row carries.
  def csv_body(rows = [%w[E0 16/08/2024 12:30 Arsenal Fulham 1 0 H]])
    header = (described_class::REQUIRED_COLUMNS + ['Time']).join(',')
    ([header] + rows.map { |row| row.join(',') }).join("\n") + "\n"
  end

  def response_for(status:, body:, location: nil)
    response = instance_double(Net::HTTPResponse, code: status.to_s, body: body)
    allow(response).to receive(:[]).with(anything).and_return(nil)
    allow(response).to receive(:[]).with('location').and_return(location)
    response
  end

  # Builds a stubbed Net::HTTP whose #request is driven by a block taking the
  # request count. The block returns a response or raises.
  def stub_http(&handler)
    count = 0
    http = instance_double(Net::HTTP)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:write_timeout=)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:verify_mode=)
    allow(http).to receive(:start).and_yield(http)
    allow(http).to receive(:request) do |request|
      count += 1
      handler ? handler.call(count, request) : response_for(status: 200, body: csv_body)
    end
    allow(Net::HTTP).to receive(:new).and_return(http)
    http
  end

  def stub_ok(body: csv_body)
    stub_http { |_count, _request| response_for(status: 200, body: body) }
  end

  describe 'season and division validation' do
    it 'accepts the canonical season label and derives the source code' do
      stub_ok

      result = downloader.download_one(season: '2024/25')

      expect(result).to be_success
      expect(result.season).to eq('2024/25')
      expect(result.season_code).to eq('2425')
    end

    it 'accepts the bare season code used by the source' do
      stub_ok

      expect(downloader.download_one(season: '2425').season_code).to eq('2425')
    end

    it 'rejects an unknown season instead of guessing' do
      expect { downloader.download_one(season: '2099/30') }
        .to raise_error(Import::CsvDownloader::InvalidInput, /season/i)
    end

    it 'rejects a blank season' do
      expect { downloader.download_one(season: '') }
        .to raise_error(Import::CsvDownloader::InvalidInput, /season/i)
    end

    it 'rejects an unsupported division' do
      # SP1 is supported since the competition expansion; a code that exists
      # nowhere in the source is the real "unsupported" case.
      expect { downloader(division: 'ZZ9').download_one(season: '2024/25') }
        .to raise_error(Import::CsvDownloader::InvalidInput, /division/i)
    end
  end

  describe 'the request' do
    it 'requests the documented HTTPS URL for the season and division' do
      http = stub_ok

      downloader.download_one(season: '2024/25')

      expect(http).to have_received(:request) do |request|
        expect(request).to be_a(Net::HTTP::Get)
        expect(request.uri.to_s).to eq('https://www.football-data.co.uk/mmz4281/2425/E0.csv')
      end
    end

    it 'uses HTTPS' do
      http = stub_ok

      downloader.download_one(season: '2024/25')

      expect(http).to have_received(:use_ssl=).with(true)
    end

    it 'sends a user agent so the source can identify the client' do
      http = stub_ok

      downloader.download_one(season: '2024/25')

      expect(http).to have_received(:request) do |request|
        expect(request['User-Agent']).to be_present
      end
    end

    it 'sets finite open and read timeouts' do
      http = stub_ok

      downloader.download_one(season: '2024/25')

      expect(http).to have_received(:open_timeout=).with(described_class::OPEN_TIMEOUT)
      expect(http).to have_received(:read_timeout=).with(described_class::READ_TIMEOUT)
      expect(described_class::OPEN_TIMEOUT).to be > 0
      expect(described_class::READ_TIMEOUT).to be > 0
    end

    it 'is bound to the official hosts' do
      expect(described_class::ALLOWED_HOST).to eq('www.football-data.co.uk')
      # The source answers on `www` with a 302 to the apex domain, which serves
      # the CSV; both are official and nothing else is permitted.
      expect(described_class::ALLOWED_HOSTS)
        .to contain_exactly('www.football-data.co.uk', 'football-data.co.uk')
    end
  end

  describe 'a successful download' do
    it 'writes the file to a deterministic path' do
      stub_ok

      result = downloader.download_one(season: '2024/25')

      expect(result.file_path).to eq(File.join(dest, '2425_E0.csv'))
      expect(File.read(result.file_path)).to eq(csv_body)
    end

    it 'reports the byte size and a SHA-256 checksum of the stored file' do
      body = csv_body
      stub_ok(body: body)

      result = downloader.download_one(season: '2024/25')

      expect(result.size).to eq(body.bytesize)
      expect(result.checksum).to eq(Digest::SHA256.hexdigest(body))
    end

    it 'leaves no temporary file behind' do
      stub_ok

      downloader.download_one(season: '2024/25')

      expect(Dir.children(dest).grep(/tmp/)).to be_empty
    end

    it 'records provenance metadata' do
      stub_ok

      result = downloader.download_one(season: '2024/25')
      metadata = JSON.parse(File.read(result.metadata_path))

      expect(metadata).to include(
        'source_url' => 'https://www.football-data.co.uk/mmz4281/2425/E0.csv',
        'season' => '2024/25',
        'season_code' => '2425',
        'division' => 'E0',
        'sha256' => result.checksum,
        'bytes' => result.size
      )
      expect(metadata['retrieved_at']).to match(/\A\d{4}-\d{2}-\d{2}T/)
      expect(metadata['has_time_column']).to be(true)
    end

    it 'does not record secrets or request headers in the metadata' do
      stub_ok

      result = downloader.download_one(season: '2024/25')

      expect(File.read(result.metadata_path)).not_to match(/authorization|token|secret|password/i)
    end
  end

  describe 'files without a Time column' do
    it 'accepts a header without Time, which older seasons omit' do
      stub_ok(body: "Div,Date,HomeTeam,AwayTeam,FTHG,FTAG,FTR\nE0,16/08/2015,Arsenal,Fulham,1,0,H\n")

      result = downloader.download_one(season: '2015/16')

      expect(result).to be_success
      expect(result).to be_missing_time_column
    end

    it 'records that the file has no Time column in its metadata' do
      stub_ok(body: "Div,Date,HomeTeam,AwayTeam,FTHG,FTAG,FTR\nE0,16/08/2015,Arsenal,Fulham,1,0,H\n")

      result = downloader.download_one(season: '2015/16')

      expect(JSON.parse(File.read(result.metadata_path))['has_time_column']).to be(false)
    end

    it 'still rejects a file missing a genuinely required column' do
      stub_ok(body: "Div,Date,HomeTeam\nE0,16/08/2015,Arsenal\n")

      expect { downloader.download_one(season: '2015/16') }
        .to raise_error(Import::CsvDownloader::InvalidContent, /column/i)
    end
  end

  describe 'rejecting bad content' do
    it 'rejects an HTML error page' do
      stub_ok(body: "<!DOCTYPE html><html><body>Not found</body></html>\n")

      expect { downloader.download_one(season: '2024/25') }
        .to raise_error(Import::CsvDownloader::InvalidContent, /html|not a csv/i)
      expect(File.exist?(File.join(dest, '2425_E0.csv'))).to be(false)
    end

    it 'rejects an empty response' do
      stub_ok(body: '')

      expect { downloader.download_one(season: '2024/25') }
        .to raise_error(Import::CsvDownloader::InvalidContent, /empty/i)
    end

    it 'rejects a header-only file with no data rows' do
      stub_ok(body: described_class::REQUIRED_COLUMNS.join(',') + "\n")

      expect { downloader.download_one(season: '2024/25') }
        .to raise_error(Import::CsvDownloader::InvalidContent, /row/i)
    end

    it 'rejects a malformed CSV body' do
      stub_ok(body: "Div,Date,Time,HomeTeam\nE0,\"unterminated,12:30,Arsenal\n")

      expect { downloader.download_one(season: '2024/25') }
        .to raise_error(Import::CsvDownloader::InvalidContent, /malformed|parse/i)
    end

    it 'accepts a body carrying non-UTF-8 bytes instead of raising an encoding error' do
      # The source has published Windows-1252 bytes (e.g. "Á" in a club name).
      # Raw binary compared against UTF-8 literals raises
      # Encoding::CompatibilityError, so the checks must decode first.
      body = csv_body([['E0', '16/08/2024', '12:30', 'Atlético', 'Fulham', '1', '0', 'H']])
      binary = body.dup.force_encoding(Encoding::ASCII_8BIT).b
      binary = binary.sub('Atl'.b + "é".b, 'Atl'.b + "é".dup.force_encoding('Windows-1252').b)
      stub_ok(body: binary)

      result = downloader.download_one(season: '2024/25')

      expect(result).to be_success
      # Stored byte-for-byte as received.
      expect(File.binread(result.file_path)).to eq(binary)
    end

    it 'leaves no partial file when content is rejected' do
      stub_ok(body: '<html></html>')

      begin
        downloader.download_one(season: '2024/25')
      rescue Import::CsvDownloader::InvalidContent
        nil
      end

      expect(Dir.children(dest)).to be_empty
    end
  end

  describe 'HTTP failures' do
    it 'reports a 404 as an unavailable season' do
      stub_http { |_count, _request| response_for(status: 404, body: 'Not Found') }

      expect { downloader.download_one(season: '2026/27') }
        .to raise_error(Import::CsvDownloader::Unavailable, /404|not available/i)
    end

    it 'creates no file for a 404' do
      stub_http { |_count, _request| response_for(status: 404, body: '') }

      begin
        downloader.download_one(season: '2026/27')
      rescue Import::CsvDownloader::Unavailable
        nil
      end

      expect(Dir.children(dest)).to be_empty
    end

    it 'does not retry a 404' do
      attempts = 0
      stub_http do |count, _request|
        attempts = count
        response_for(status: 404, body: '')
      end

      expect { downloader.download_one(season: '2026/27') }
        .to raise_error(Import::CsvDownloader::Unavailable)
      expect(attempts).to eq(1)
    end

    it 'retries a server error within a bounded attempt count and then gives up' do
      attempts = 0
      stub_http do |count, _request|
        attempts = count
        response_for(status: 500, body: 'oops')
      end
      allow(downloader).to receive(:sleep)

      expect { downloader.download_one(season: '2024/25') }
        .to raise_error(Import::CsvDownloader::TransientError)
      expect(attempts).to eq(described_class::MAX_ATTEMPTS)
    end

    it 'retries a connection reset and succeeds on a later attempt' do
      attempts = 0
      stub_http do |count, _request|
        attempts = count
        raise Errno::ECONNRESET if count == 1

        response_for(status: 200, body: csv_body)
      end
      allow(downloader).to receive(:sleep)

      result = downloader.download_one(season: '2024/25')

      expect(result).to be_success
      expect(attempts).to eq(2)
    end

    it 'follows a redirect to the same host' do
      stub_http do |count, _request|
        if count == 1
          response_for(status: 302, body: '',
                       location: 'https://www.football-data.co.uk/mmz4281/2425/E0.csv')
        else
          response_for(status: 200, body: csv_body)
        end
      end

      expect(downloader.download_one(season: '2024/25')).to be_success
    end

    it 'follows the real www -> apex redirect that the source performs' do
      stub_http do |count, _request|
        if count == 1
          response_for(status: 302, body: '',
                       location: 'https://football-data.co.uk/mmz4281/2425/E0.csv')
        else
          response_for(status: 200, body: csv_body)
        end
      end

      expect(downloader.download_one(season: '2024/25')).to be_success
    end

    it 'refuses a redirect to another host' do
      stub_http do |_count, _request|
        response_for(status: 302, body: '', location: 'https://evil.example/E0.csv')
      end

      expect { downloader.download_one(season: '2024/25') }
        .to raise_error(Import::CsvDownloader::InvalidContent, /redirect|host/i)
    end

    it 'refuses a lookalike host that merely ends with the official domain' do
      stub_http do |_count, _request|
        response_for(status: 302, body: '',
                     location: 'https://notfootball-data.co.uk/mmz4281/2425/E0.csv')
      end

      expect { downloader.download_one(season: '2024/25') }
        .to raise_error(Import::CsvDownloader::InvalidContent, /redirect|host/i)
    end

    it 'bounds redirect chains instead of looping forever' do
      stub_http do |_count, _request|
        response_for(status: 302, body: '',
                     location: 'https://www.football-data.co.uk/mmz4281/2425/E0.csv')
      end

      expect { downloader.download_one(season: '2024/25') }
        .to raise_error(Import::CsvDownloader::InvalidContent, /redirect/i)
    end
  end

  describe 'existing files' do
    let(:existing) { File.join(dest, '2425_E0.csv') }

    before do
      File.write(existing, csv_body)
      allow(Net::HTTP).to receive(:new).and_raise('must not download over an existing file')
    end

    it 'reports the file as already present without downloading' do
      result = downloader.download_one(season: '2024/25')

      expect(result).to be_already_present
      expect(result.downloaded).to be(false)
      expect(result.checksum).to eq(Digest::SHA256.file(existing).hexdigest)
    end

    it 'leaves the existing file untouched' do
      before_content = File.read(existing)

      downloader.download_one(season: '2024/25')

      expect(File.read(existing)).to eq(before_content)
    end

    it 'replaces the file only when overwrite is explicit' do
      stub_ok(body: csv_body([%w[E0 17/08/2024 15:00 Chelsea Everton 2 1 H]]))

      result = downloader(overwrite: true).download_one(season: '2024/25')

      expect(result).to be_success
      expect(File.read(existing)).to include('Chelsea')
    end
  end

  describe '.download' do
    it 'downloads several seasons and returns one result per season' do
      stub_ok

      results = downloader.download(seasons: %w[2024/25 2025/26])

      expect(results.length).to eq(2)
      expect(results.map(&:season)).to eq(%w[2024/25 2025/26])
      expect(results).to all(be_success)
    end

    it 'requires an explicit season list rather than downloading everything' do
      expect { downloader.download(seasons: []) }
        .to raise_error(Import::CsvDownloader::InvalidInput, /season/i)
    end
  end

  describe 'safety of the destination' do
    it 'writes beneath data/raw, which is git-ignored with .gitkeep preserved' do
      # The destination is the project's ignored raw area, not the committed
      # fixtures. Checked by path, so it holds regardless of what is mounted.
      expect(described_class::DEFAULT_DESTINATION).to end_with(File.join('data', 'raw'))
    end

    it 'does not write into the committed fixtures directory' do
      expect(described_class::DEFAULT_DESTINATION).not_to include('fixtures')
    end
  end
end