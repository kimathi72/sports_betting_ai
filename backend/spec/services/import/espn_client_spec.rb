require "rails_helper"

# Exercises the ESPN client's HTTP contract without touching the network.
#
# WHY A DATE WINDOW
# -----------------
# The scoreboard endpoint serves one DAY per request when given `YYYYMMDD`, and
# it returns zero events for every range form (`20260801-20260831`,
# `2026-08-21-2026-08-31`) that was tried against the live API. Discovery is
# therefore explicit: walk the days and merge the events.
#
# The defect this file guards against is not a parsing bug but a COVERAGE bug:
# the original rake task only fetched the dates an operator typed, so the gaps
# between them were never requested at all. Nothing in the client could have
# reported that, because every individual request succeeded.
RSpec.describe Import::EspnClient do
  subject(:client) { described_class.new }

  # Replaces the transport so the specs never hit ESPN.
  def stub_scoreboard(map)
    allow(client).to receive(:perform) do |uri|
      date = uri.query.to_s[/dates=(\w+)/, 1]
      events = map.fetch(date, [])
      body = { "events" => events }.to_json
      response = Net::HTTPOK.new("1.1", "200", "OK")
      allow(response).to receive(:body).and_return(body)
      allow(response).to receive(:[]).with("content-encoding").and_return(nil)
      response
    end
  end

  describe "#scoreboard_dates" do
    it "merges events from every day in the window" do
      stub_scoreboard(
        "20261031" => [{ "id" => "1" }],
        "20261101" => [{ "id" => "2" }],
        "20261102" => [{ "id" => "3" }],
      )

      result = client.scoreboard_dates(
        league: "eng.1", from_date: Date.new(2026, 10, 31), to_date: Date.new(2026, 11, 2),
      )

      expect(result.events.map { |e| e["id"] }).to eq(%w[1 2 3])
    end

    it "requests every calendar day in the range, including empty ones" do
      requested = []
      allow(client).to receive(:perform) do |uri|
        requested << uri.query
        response = Net::HTTPOK.new("1.1", "200", "OK")
        allow(response).to receive(:body).and_return({ "events" => [] }.to_json)
        allow(response).to receive(:[]).with("content-encoding").and_return(nil)
        response
      end

      client.scoreboard_dates(
        league: "eng.1", from_date: Date.new(2026, 10, 30), to_date: Date.new(2026, 11, 2),
      )

      expect(requested).to eq(
        %w[dates=20261030 dates=20261031 dates=20261101 dates=20261102]
      )
    end

    it "reports which days carried events, so a gap can be told from an empty day" do
      stub_scoreboard("20261101" => [{ "id" => "9" }])

      result = client.scoreboard_dates(
        league: "eng.1", from_date: Date.new(2026, 10, 31), to_date: Date.new(2026, 11, 1),
      )

      expect(result.days).to eq("20261031" => 0, "20261101" => 1)
    end

    it "treats an inverted range as empty instead of iterating forever" do
      expect { client.scoreboard_dates(league: "eng.1", from_date: Date.new(2026, 11, 2), to_date: Date.new(2026, 11, 1)) }.not_to raise_error
      expect(client.scoreboard_dates(league: "eng.1", from_date: Date.new(2026, 11, 2), to_date: Date.new(2026, 11, 1)).events).to eq([])
    end

    it "refuses a window longer than a season rather than hammering the provider" do
      expect do
        client.scoreboard_dates(
          league: "eng.1", from_date: Date.new(2026, 1, 1), to_date: Date.new(2028, 1, 1),
        )
      end.to raise_error(ArgumentError, /window/i)
    end
  end
end
