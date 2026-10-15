FROM ruby:3.3.12-slim

ENV RAILS_ENV=development \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3

# Runtime and build dependencies:
#  - build-essential / libpq-dev: native gems (pg)
#  - postgresql-client: pg_isready and psql for readiness checks
#  - git: some gems resolved from GitHub
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential \
      libpq-dev \
      postgresql-client \
      git \
      curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

# Entrypoint waits for PostgreSQL and runs pending migrations once,
# so web and sidekiq never race each other with concurrent migrations.
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
