# Loads FactoryBot definitions and gives specs `build`/`create` without a prefix.
RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods
end
