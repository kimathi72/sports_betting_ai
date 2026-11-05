require "rails_helper"

# The API-Football HTTP client.
#
# Every test here is fully mocked: the free plan allows 100 requests per day, so
# a suite that touched the network would exhaust the quota and start failing for
# reasons unrelated to the code. Live connectivity is verified separately, by
# hand, and never from CI.
#
# The secret is loaded from ENV at call time, never stored on the class, so a
# stray `inspect` or log line cannot print it.
RSpec.describe Import::ApiFootballClient do
  let(:base_url) { "https://v3.football.api-sports.io" }
  let(:api_key) { "test-key-not-a-real-credential" }

  around do |example|
    original = ENV.to_h.slice("API_FOOTBALL_BASE_URL", "API_FOOTBALL_API_KEY")
    ENV["API_FOOTBALL_BASE_URL"] = base_url
    ENV["API_FOOTBALL_API_KEY"] = api_key
    example.run
    ENV.delete("API_FOOTBALL_BASE_URL")
    ENV.delete("API_FOOTBALL_API_KEY")
    ENV.update(original)
  end

  def ok_body(response_payload, results: nil)
    {
      "get" => "fixtures",
      "parameters" => {},
      "errors" => [],
      "results" => results || response_payload.size,
      "paging" => { "current" => 1, "total" => 1 },
      "response" => response_payload,
    }.to_json
  end

  def stub_http(status:, body:, headers: {})
    response = instance_double(Net::HTTPResponse, code: status.to_s, body: body)
    allow(response).to receive(:[]).and_return(nil)
    headers.each { |key, value| allow(response).to receive(:[]).with(key).and_return(value) }

    http = instance_double(Net::HTTP)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:start).and_yield(http)
    allow(http).to receive(:request).and_return(response)
    allow(Net::HTTP).to receive(:new).and_return(http)
    [http, response]
  end

  describe "configuration" do
    it "raises a configuration error when credentials are absent" do
      ENV.delete("API_FOOTBALL_API_KEY")

      expect { described_class.new.get("/status") }.to raise_error(Import::ApiFootballClient::ConfigurationError, /API_FOOTBALL_API_KEY/)
    end

    it "never includes the key in a configuration error message" do
      ENV["API_FOOTBALL_BASE_URL"] = "http://"

      error = begin
          described_class.new.get("/status")
        rescue Import::ApiFootballClient::ConfigurationError => e
          e
        end

      expect(error.message).not_to include(api_key)
    end
  end

  describe "requests" do
    it "sends the key in the x-apisports-key header" do
      http, = stub_http(status: 200, body: ok_body([]))

      described_class.new.get("/status")

      expect(http).to have_received(:request) do |request|
        expect(request["x-apisports-key"]).to eq(api_key)
      end
    end

    it "sets connection and read timeouts" do
      http, = stub_http(status: 200, body: ok_body([]))

      described_class.new.get("/status")

      expect(http).to have_received(:open_timeout=).with(Import::ApiFootballClient::OPEN_TIMEOUT)
      expect(http).to have_received(:read_timeout=).with(Import::ApiFootballClient::READ_TIMEOUT)
    end

    it "returns the response array and the request quota headers" do
      _, = stub_http(
        status: 200,
        body: ok_body([{ "fixture" => { "id" => 1 } }]),
        headers: {
          "x-ratelimit-requests-remaining" => "87",
          "x-ratelimit-requests-limit" => "100",
        },
      )

      result = described_class.new.get("/fixtures", query: { league: 39, season: 2024 })

      expect(result.records).to eq([{ "fixture" => { "id" => 1 } }])
      expect(result.quota_remaining).to eq(87)
      expect(result.quota_limit).to eq(100)
    end

    it "never logs the credential" do
      # Spying on the logger is the only way to prove the key cannot reach the
      # log stream, which is where a secret usually escapes.
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:debug)
      allow(Rails.logger).to receive(:warn)
      allow(Rails.logger).to receive(:error)

      stub_http(status: 200, body: ok_body([]))
      described_class.new.get("/status")

      %i[info debug warn error].each do |level|
        expect(Rails.logger).not_to have_received(level).with(/#{Regexp.escape(api_key)}/)
      end
    end
  end

  describe "failure classification" do
    # Transient: worth retrying. Permanent: retrying cannot help and on a
    # 100-request/day quota a retry is genuinely costly.
    it "classifies a 401 as a permanent authentication failure" do
      stub_http(status: 401, body: '{"errors":[]}')

      expect { described_class.new.get("/status") }.to raise_error(Import::ApiFootballClient::AuthenticationError)
    end

    it "classifies a 429 as a rate limit and reports the retry window" do
      stub_http(
        status: 429,
        body: '{"errors":{"rateLimit":"Too many requests"}}',
        headers: { "retry-after" => "30" },
      )

      expect { described_class.new.get("/status") }.to raise_error(Import::ApiFootballClient::RateLimitError) { |error|
        expect(error.retry_after_seconds).to eq(30)
      }
    end

    it "classifies a 5xx as transient" do
      stub_http(status: 503, body: "")

      expect { described_class.new.get("/status") }.to raise_error(Import::ApiFootballClient::TransientError)
    end

    it "classifies a timeout as transient" do
      http = instance_double(Net::HTTP)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:start).and_yield(http)
      allow(http).to receive(:request).and_raise(Net::ReadTimeout)
      allow(Net::HTTP).to receive(:new).and_return(http)

      expect { described_class.new.get("/status") }.to raise_error(Import::ApiFootballClient::TransientError, /timed out/i)
    end

    it "classifies a connection refusal as transient" do
      allow(Net::HTTP).to receive(:new).and_raise(Errno::ECONNREFUSED)

      expect { described_class.new.get("/status") }.to raise_error(Import::ApiFootballClient::TransientError)
    end

    it "classifies malformed JSON as a permanent content failure" do
      stub_http(status: 200, body: "<html>not json</html>")

      expect { described_class.new.get("/status") }.to raise_error(Import::ApiFootballClient::InvalidContentError)
    end

    it "raises on an API-level error returned inside a 200 response" do
      # API-Football reports plan restrictions this way: HTTP 200, errors
      # populated, response empty. Treating that as success would import nothing
      # and report a healthy run.
      stub_http(
        status: 200,
        body: { "errors" => { "plan" => "Free plans do not have access to this season" },
                "results" => 0, "response" => [] }.to_json,
      )

      expect { described_class.new.get("/fixtures", query: { season: 2026 }) }.to raise_error(Import::ApiFootballClient::ApiError) { |error|
        expect(error.message).to include("Free plans do not have access")
      }
    end

    it "accepts errors returned as an empty array" do
      stub_http(status: 200, body: { "errors" => [], "results" => 0, "response" => [] }.to_json)

      expect(described_class.new.get("/status").records).to eq([])
    end

    it "rejects a response missing the expected keys" do
      stub_http(status: 200, body: '{"unexpected":true}')

      expect { described_class.new.get("/status") }.to raise_error(Import::ApiFootballClient::InvalidContentError, /response/)
    end
  end

  describe "#inspect" do
    it "does not leak the key" do
      stub_http(status: 200, body: ok_body([]))

      expect(described_class.new.inspect).not_to include(api_key)
    end
  end
end
