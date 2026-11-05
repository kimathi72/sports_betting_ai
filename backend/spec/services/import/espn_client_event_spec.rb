require "rails_helper"

# `EspnClient#event` must return a payload the ADAPTER can read.
#
# THE INCIDENT (2026-11-05)
# -------------------------
# The first live run recorded every check as `rejected` with reason
# "unusable payload". The summary endpoint nests the competition under `header`,
# and the client returned that bare competition — but `EspnAdapter#normalize_fixture`
# reads `payload['competitions']`, because that is how a SCOREBOARD event is
# shaped. The adapter therefore saw no competitions and rejected every event.
#
# The unit specs passed because they stubbed `client.event` with a payload already
# in the scoreboard shape. This spec pins the real shape instead.
RSpec.describe Import::EspnClient, "#event" do
  # The real summary response, trimmed to the fields that matter.
  let(:summary_body) do
    {
      "header" => {
        "id" => "401878967",
        "season" => { "year" => 2026 },
        "competitions" => [
          {
            "id" => "401878967",
            "date" => "2026-11-02T20:00Z",
            "status" => { "type" => { "name" => "STATUS_FULL_TIME", "state" => "post",
                                      "completed" => true } },
            "competitors" => [
              { "homeAway" => "home", "team" => { "id" => "361", "displayName" => "Newcastle United" },
                "score" => "0" },
              { "homeAway" => "away", "team" => { "id" => "368", "displayName" => "Everton" },
                "score" => "1" }
            ]
          }
        ]
      }
    }
  end

  # `decompress` is stubbed, so the double only needs the status code.
  let(:response) { instance_double(Net::HTTPResponse, code: "200") }

  let(:client) { described_class.new }

  before do
    allow(client).to receive(:perform).and_return(response)
    allow(client).to receive(:decompress).and_return(JSON.generate(summary_body))
  end

  it "returns a payload with a top-level competitions array" do
    payload = client.event(league: "eng.1", event_id: "401878967")

    expect(payload["competitions"]).to be_an(Array)
    expect(payload["competitions"].size).to eq(1)
  end

  it "carries the event id and date at the top level" do
    payload = client.event(league: "eng.1", event_id: "401878967")

    expect(payload["id"]).to eq("401878967")
    expect(payload["date"]).to eq("2026-11-02T20:00Z")
  end

  it "produces a payload the adapter can normalise" do
    payload = client.event(league: "eng.1", event_id: "401878967")

    row = Import::EspnAdapter.new.normalize_fixture(payload)

    expect(row).not_to be_nil
    expect(row.status).to eq("completed")
    expect([row.home_score, row.away_score]).to eq([0, 1])
    expect(row.provider_key).to eq("401878967")
  end

  it "raises a permanent error for a 404" do
    allow(client).to receive(:perform).and_return(
      instance_double(Net::HTTPResponse, code: "404")
    )

    expect { client.event(league: "eng.1", event_id: "nope") }
      .to raise_error(Import::EspnClient::InvalidContentError, /no event/)
  end

  it "raises a transient error for a 5xx" do
    allow(client).to receive(:perform).and_return(
      instance_double(Net::HTTPResponse, code: "503")
    )

    expect { client.event(league: "eng.1", event_id: "x") }
      .to raise_error(Import::EspnClient::TransientError)
  end
end
