# frozen_string_literal: true

require "time"
require_relative "testflight_gateway_errors"
require_relative "testflight_release_guard"

module TestFlightConnectApiGateway
  MAX_PAGES = 100
  DEFAULT_READ_RETRIES = 3
  DEFAULT_READ_RETRY_BUDGET_SECONDS = 60
  MAX_RETRY_DELAY_SECONDS = 30
  RETRYABLE_READ_STATUSES = [429, *(500..599)].freeze

  class MonotonicClock
    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  class Sleeper
    def sleep(seconds)
      Kernel.sleep(seconds)
    end
  end

  class Page < Struct.new(:items, :next_cursor, keyword_init: true)
    def initialize(items:, next_cursor:)
      super(items: items.freeze, next_cursor: next_cursor)
      freeze
    end
  end

  class Gateway
    def initialize(token:, transport:, clock: MonotonicClock.new, sleeper: Sleeper.new,
                   read_retries: DEFAULT_READ_RETRIES,
                   read_retry_budget_seconds: DEFAULT_READ_RETRY_BUDGET_SECONDS)
      @token = token
      @transport = transport
      @clock = clock
      @sleeper = sleeper
      @read_retries = read_retries
      @read_retry_budget_seconds = read_retry_budget_seconds
      validate_retry_policy!
    end

    def apps(bundle_id:)
      collect(:apps, bundle_id: bundle_id).map do |raw|
        TestFlightReleaseGuard::App.new(
          id: value(raw, :id),
          bundle_id: attribute(raw, :bundle_id, :bundleId)
        )
      end.select { |app| app.bundle_id == bundle_id }.freeze
    end

    def internal_groups(app_id:, name:)
      collect(:beta_groups, app_id: app_id, name: name).map do |raw|
        TestFlightReleaseGuard::Group.new(
          id: value(raw, :id),
          app_id: relationship_id(raw, :app_id, :app) || app_id,
          name: attribute(raw, :name),
          internal: attribute(raw, :internal, :isInternalGroup) == true
        )
      end.select { |group| group.app_id == app_id && group.name == name && group.internal }.freeze
    end

    def users(email:)
      collect(:users, email: email).map do |raw|
        TestFlightReleaseGuard::User.new(
          id: value(raw, :id),
          email: attribute(raw, :email, :username),
          roles: array_attribute(raw, :roles).map(&:upcase),
          app_ids: relationship_ids(raw, :app_ids, :visibleApps),
          all_apps_access: attribute(raw, :all_apps_access, :allAppsVisible) == true
        )
      end.select { |user| user.email.to_s.casecmp(email).zero? }.freeze
    end

    def beta_testers(app_id:, email:)
      collect(:beta_testers, app_id: app_id, email: email).map do |raw|
        TestFlightReleaseGuard::BetaTester.new(
          id: value(raw, :id),
          app_id: relationship_id(raw, :app_id, :apps) || app_id,
          email: attribute(raw, :email),
          invite_type: attribute(raw, :invite_type, :inviteType)&.to_s&.upcase,
          group_ids: relationship_ids(raw, :group_ids, :betaGroups)
        )
      end.select { |tester| tester.app_id == app_id && tester.email.to_s.casecmp(email).zero? }.freeze
    end

    def builds(app_id:, version:)
      collect(:builds, app_id: app_id, version: version).map do |raw|
        TestFlightReleaseGuard::Build.new(
          id: value(raw, :id),
          app_id: relationship_id(raw, :app_id, :app) || app_id,
          version: attribute(raw, :version) || version,
          build_number: attribute(raw, :build_number, :version_number, :version),
          processing_state: attribute(raw, :processing_state, :processingState)&.to_s&.upcase,
          internal_state: attribute(raw, :internal_state, :internalBuildState)&.to_s&.upcase,
          expired: attribute(raw, :expired),
          expiration_date: parse_time(attribute(raw, :expiration_date, :expirationDate)),
          uses_non_exempt_encryption: attribute(raw, :uses_non_exempt_encryption, :usesNonExemptEncryption),
          group_ids: relationship_ids(raw, :group_ids, :betaGroups)
        )
      end.select { |build| build.app_id == app_id && build.version == version }.freeze
    end

    def associate_build_to_group(build_id:, group_id:)
      renewed = false
      begin
        @transport.associate_build_to_group(build_id: build_id, group_id: group_id, token: @token)
      rescue Unauthorized
        raise AuthenticationFailure, "App Store Connect authentication failed after token renewal" if renewed

        @token = @transport.refresh_token
        renewed = true
        retry
      end
    rescue RemoteResponseError => error
      raise Conflict, "Build relationship already changed" if error.status == 409
      if error.status.is_a?(Integer) && error.status.between?(500, 599)
        raise AmbiguousMutation, "App Store Connect mutation outcome is ambiguous"
      end

      raise RemoteFailure, "App Store Connect mutation failed with status #{sanitized_status(error.status)}"
    rescue TransportAmbiguous
      raise AmbiguousMutation, "App Store Connect mutation outcome is ambiguous"
    end

    private

    def collect(resource, filters)
      cursor = nil
      cursors = {}
      items = []
      pages = 0
      renewed = false
      retries = 0
      retry_started_at = @clock.now

      loop do
        raise RemoteFailure, "App Store Connect pagination exceeded its safety limit" if pages >= MAX_PAGES
        raise RemoteFailure, "App Store Connect pagination cursor repeated" if cursors.key?(cursor)

        cursors[cursor] = true
        begin
          page = @transport.fetch(resource: resource, filters: filters, cursor: cursor, token: @token)
        rescue Unauthorized
          raise AuthenticationFailure, "App Store Connect authentication failed after token renewal" if renewed

          @token = @transport.refresh_token
          renewed = true
          cursors.delete(cursor)
          retry
        rescue RemoteResponseError => error
          if retryable_read?(error.status) && retry_allowed?(retries, retry_started_at)
            delay = retry_delay(error.retry_after, retries, retry_started_at)
            @sleeper.sleep(delay)
            retries += 1
            retry
          end
          raise RemoteFailure, "App Store Connect request failed with status #{sanitized_status(error.status)}"
        rescue TransportAmbiguous
          raise RemoteFailure, "App Store Connect request outcome is ambiguous"
        end

        items.concat(page.items)
        pages += 1
        retries = 0
        cursor = page.next_cursor
        break if cursor.nil?
      end
      items.freeze
    end

    def value(raw, key)
      return raw.public_send(key) if !raw.is_a?(Hash) && raw.respond_to?(key)

      return raw[key] if raw.key?(key)

      string_key = key.to_s
      raw[string_key] if raw.key?(string_key)
    end

    def attributes(raw)
      value(raw, :attributes) || {}
    end

    def attribute(raw, *keys)
      keys.each do |key|
        direct = value(raw, key)
        return direct unless direct.nil?

        nested = value(attributes(raw), key)
        return nested unless nested.nil?
      end
      nil
    end

    def array_attribute(raw, *keys)
      Array(attribute(raw, *keys)).map(&:to_s)
    end

    def relationship_id(raw, direct_key, relationship_key)
      direct = value(raw, direct_key)
      return direct unless direct.nil?

      relationship_ids(raw, direct_key, relationship_key).first
    end

    def relationship_ids(raw, direct_key, relationship_key)
      direct = value(raw, direct_key)
      return Array(direct).map(&:to_s) unless direct.nil?

      relationships = value(raw, :relationships) || {}
      relationship = value(relationships, relationship_key) || {}
      data = value(relationship, :data)
      Array(data).map { |entry| value(entry, :id).to_s }.reject(&:empty?)
    end

    def parse_time(value)
      return value if value.is_a?(Time) || value.nil?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def sanitized_status(status)
      status.is_a?(Integer) ? status : "unknown"
    end

    def retryable_read?(status)
      RETRYABLE_READ_STATUSES.include?(status)
    end

    def retry_allowed?(retries, started_at)
      retries < @read_retries && retry_budget_remaining(started_at).positive?
    end

    def retry_delay(retry_after, retries, started_at)
      requested = sanitized_retry_after(retry_after) || (2**retries)
      [requested, MAX_RETRY_DELAY_SECONDS, retry_budget_remaining(started_at)].min
    end

    def sanitized_retry_after(value)
      seconds = Float(value)
      return nil unless seconds.finite? && seconds >= 0

      seconds
    rescue ArgumentError, TypeError
      nil
    end

    def retry_budget_remaining(started_at)
      @read_retry_budget_seconds - (@clock.now - started_at)
    end

    def validate_retry_policy!
      unless @read_retries.is_a?(Integer) && @read_retries >= 0
        raise ArgumentError, "read_retries must be a non-negative integer"
      end
      unless @read_retry_budget_seconds.is_a?(Numeric) && @read_retry_budget_seconds.positive?
        raise ArgumentError, "read_retry_budget_seconds must be positive"
      end
    end
  end

  class SpaceshipTransport
    RESOURCE_MODELS = {
      apps: :App,
      beta_groups: :BetaGroup,
      users: :User,
      beta_testers: :BetaTester,
      builds: :Build
    }.freeze

    def initialize(api_key_configuration:)
      @api_key_configuration = api_key_configuration
      @loaded_resources = {}
    end

    def refresh_token
      require "spaceship"
      token = Spaceship::ConnectAPI::Token.create(
        key_id: @api_key_configuration.key_id,
        issuer_id: @api_key_configuration.issuer_id,
        filepath: @api_key_configuration.key_path
      )
      Spaceship::ConnectAPI.token = token
      token
    rescue LoadError
      raise RemoteFailure, "Fastlane Spaceship is unavailable"
    rescue StandardError
      raise AuthenticationFailure, "App Store Connect token creation failed"
    end

    def fetch(resource:, filters:, cursor:, token:)
      raise RemoteFailure, "Unsupported App Store Connect resource" unless RESOURCE_MODELS.key?(resource)

      load_resource(resource, filters, token) if cursor.nil?
      items = @loaded_resources.fetch(resource)
      offset = cursor.nil? ? 0 : Integer(cursor, 10)
      page_items = items.slice(offset, 200) || []
      next_cursor = offset + page_items.length < items.length ? (offset + page_items.length).to_s : nil
      Page.new(items: page_items.map { |model| snapshot(resource, model) }, next_cursor: next_cursor)
    rescue ArgumentError
      raise RemoteFailure, "App Store Connect returned an invalid pagination cursor"
    rescue RemoteFailure, AuthenticationFailure
      raise
    rescue StandardError => error
      status = response_status(error)
      raise Unauthorized, "App Store Connect token expired" if status == 401

      raise RemoteResponseError.new(status: status, body: nil, retry_after: response_retry_after(error))
    end

    def associate_build_to_group(build_id:, group_id:, token:)
      activate(token)
      Spaceship::ConnectAPI.add_beta_groups_to_build(
        build_id: build_id,
        beta_group_ids: [group_id]
      )
      true
    rescue StandardError => error
      status = response_status(error)
      raise Unauthorized, "App Store Connect token expired" if status == 401
      raise RemoteResponseError.new(status: status, body: nil) if status

      raise TransportAmbiguous, "App Store Connect relationship request did not complete"
    end

    private

    def load_resource(resource, filters, token)
      activate(token)
      @loaded_resources[resource] = case resource
                                    when :apps
                                      model(:App).all(filter: api_filters(resource, filters))
                                    when :beta_groups
                                      app(filters.fetch(:app_id)).get_beta_groups
                                    when :users
                                      model(:User).all(filter: api_filters(resource, filters))
                                    when :beta_testers
                                      model(:BetaTester).all(
                                        filter: api_filters(resource, filters),
                                        includes: "apps,betaGroups"
                                      )
                                    when :builds
                                      model(:Build).all(
                                        app_id: filters.fetch(:app_id),
                                        version: filters.fetch(:version)
                                      )
                                    end
    end

    def activate(token)
      require "spaceship"
      Spaceship::ConnectAPI.token = token
    rescue LoadError
      raise RemoteFailure, "Fastlane Spaceship is unavailable"
    end

    def model(name)
      Spaceship::ConnectAPI.const_get(name)
    end

    def app(app_id)
      model(:App).get(app_id: app_id)
    end

    def api_filters(resource, filters)
      case resource
      when :apps
        { bundleId: filters.fetch(:bundle_id) }
      when :beta_groups
        { app: filters.fetch(:app_id) }
      when :users
        {}
      when :beta_testers
        { apps: filters.fetch(:app_id) }
      when :builds
        {}
      end
    end

    def snapshot(resource, model_instance)
      case resource
      when :apps
        { id: read(model_instance, :id), bundle_id: read(model_instance, :bundle_id) }
      when :beta_groups
        {
          id: read(model_instance, :id),
          app_id: related_id(model_instance, :app),
          name: read(model_instance, :name),
          internal: read(model_instance, :is_internal_group)
        }
      when :users
        {
          id: read(model_instance, :id),
          email: read(model_instance, :username, :email),
          roles: read(model_instance, :roles) || [],
          app_ids: related_ids(model_instance, :visible_apps),
          all_apps_access: read(model_instance, :all_apps_visible)
        }
      when :beta_testers
        {
          id: read(model_instance, :id),
          app_id: related_ids(model_instance, :apps).first,
          email: read(model_instance, :email),
          invite_type: read(model_instance, :invite_type),
          group_ids: related_ids(model_instance, :beta_groups)
        }
      when :builds
        {
          id: read(model_instance, :id),
          app_id: related_id(model_instance, :app),
          version: read(model_instance, :pre_release_version)&.then { |item| read(item, :version) },
          build_number: read(model_instance, :version),
          processing_state: read(model_instance, :processing_state),
          internal_state: read(read(model_instance, :build_beta_detail), :internal_build_state),
          expired: read(model_instance, :expired),
          expiration_date: read(model_instance, :expiration_date),
          uses_non_exempt_encryption: read(model_instance, :uses_non_exempt_encryption),
          group_ids: group_ids_for_build(model_instance)
        }
      end.freeze
    end

    def read(object, *names)
      names.each { |name| return object.public_send(name) if object.respond_to?(name) }
      nil
    end

    def related_id(object, name)
      related = read(object, name)
      read(related, :id)
    end

    def related_ids(object, name)
      Array(read(object, name)).map { |related| read(related, :id).to_s }.reject(&:empty?)
    end

    def group_ids_for_build(build)
      app_id = related_id(build, :app)
      return [] unless app_id

      app(app_id).get_beta_groups.select do |group|
        group.fetch_builds.any? { |related_build| related_build.id == build.id }
      end.map(&:id)
    end

    def response_status(error)
      return error.status.to_i if error.respond_to?(:status)
      return error.response.status.to_i if error.respond_to?(:response) && error.response.respond_to?(:status)

      nil
    end

    def response_retry_after(error)
      return nil unless error.respond_to?(:response) && error.response.respond_to?(:headers)

      headers = error.response.headers
      headers["retry-after"] || headers["Retry-After"]
    rescue StandardError
      nil
    end
  end
end
