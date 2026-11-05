# Be sure to restart your server when you modify this file.
#
# CORS for the mobile client.
#
# WHY THIS IS NEEDED AT ALL. Native React Native networking (iOS/Android) does
# not enforce the browser's same-origin policy, so the app talks to Rails with or
# without this file. Expo does, in two places:
#
#   - `expo start --web` serves the app from http://localhost:8081 and the browser
#     sends a real cross-origin request;
#   - Expo Go on a device is native, but any web view or browser-based debugging
#     is not.
#
# Without a CORS policy those browser contexts fail every request. This is a
# BROWSER policy only: it has nothing to do with whether the device can reach
# Rails over the Docker network or LAN — that is governed by the Compose port
# mapping and by `localhost` meaning "the phone itself" on a physical device.
#
# POLICY
# ------
#   - Origins come from CORS_ORIGINS (comma-separated), so a developer's LAN
#     address or Expo tunnel can be added without a code change.
#   - Development/test default to the Expo dev-server origins on localhost.
#   - Production has NO default. If CORS_ORIGINS is unset in production the policy
#     is empty, which means no browser origin is allowed. A wildcard is never
#     used in production: this API has no credentials today, but a wildcard is the
#     kind of default that silently survives the day authentication is added.
#   - Credentials are NOT enabled. The API is read-mostly, unauthenticated and
#     uses no cookies, so `credentials: true` would only widen what a browser may
#     send.
#   - Only the methods the API actually exposes are permitted, plus OPTIONS for
#     the preflight itself.
#
# rack-cors answers the OPTIONS preflight automatically for any allowed origin.
#
# Format of CORS_ORIGINS (comma-separated, scheme + host + optional port, no
# trailing slash):
#
#   CORS_ORIGINS=http://localhost:8081,http://192.168.1.20:8081
#
# A value of `*` is honoured in development only, so an Expo tunnel can be used
# without enumerating its URL. It is ignored in production.

DEVELOPMENT_CORS_ORIGINS = %w[
  http://localhost:8081
  http://127.0.0.1:8081
  http://127.0.0.1:8082
  http://localhost:19006
  http://127.0.0.1:19006
].freeze

configured_origins = ENV.fetch('CORS_ORIGINS', '').split(',').map(&:strip).reject(&:empty?)

# Rails autoloads `config/initializers` before the environment file is fully
# applied, so `Rails.env` is the reliable source here.
cors_origins =
  if configured_origins.any?
    configured_origins
  elsif Rails.env.production?
    []
  else
    DEVELOPMENT_CORS_ORIGINS
  end

# A wildcard is a development convenience only. `*` never reaches production even
# if someone sets it there by accident.
cors_origins = ['*'] if cors_origins == ['*'] && !Rails.env.production?

if cors_origins.any?
  Rails.application.config.middleware.insert_before 0, Rack::Cors do
    allow do
      origins(*cors_origins)

      resource '*',
               headers: :any,
               methods: %i[get post options head],
               max_age: 600
    end
  end
else
  Rails.logger.warn(
    '[cors] CORS_ORIGINS is empty; browser clients will be refused. ' \
    'Native React Native requests are unaffected.'
  )
end
