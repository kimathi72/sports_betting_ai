# Coverage is opt-in to keep local runs fast; enable with COVERAGE=true.
if ENV["COVERAGE"] == "true"
  require "simplecov"
  SimpleCov.start "rails" do
    add_filter "/spec/"
    add_filter "/config/"
  end
end
