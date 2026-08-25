# Redis::Config vive em lib/ (eager_load, só carregado adiante). Como o config.cache_store abaixo
# é avaliado já na fase de boot (antes do Zeitwerk e dos initializers), carregamos explicitamente —
# mesmo padrao do config/initializers/sidekiq.rb. Chatwoot.redis_ssl_verify_mode (usado por
# Redis::Config.app) ja esta disponivel: vem de config/application.rb, carregado antes deste arquivo.
require Rails.root.join('lib/redis/config')

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.cache_classes = true
  config.assets.enabled = false
  # Eager load code on boot. This eager loads most of Rails and
  # your application in memory, allowing both threaded web servers
  # and those relying on copy on write to perform better.
  # Rake tasks automatically ignore this option for performance.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local       = false
  config.action_controller.perform_caching = true

  # Disable serving static files from the `/public` folder by default since
  # Apache or NGINX already handles this.
  config.public_file_server.enabled = ENV['RAILS_SERVE_STATIC_FILES'].present?

  # Compress JavaScripts and CSS.
  config.assets.js_compressor = :uglifier
  # config.assets.css_compressor = :sass

  # Do not fallback to assets pipeline if a precompiled asset is missed.
  config.assets.compile = false

  # `config.assets.precompile` and `config.assets.version` have moved to config/initializers/assets.rb

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.action_controller.asset_host = 'http://assets.example.com'

  # Specifies the header that your server uses for sending files.
  # config.action_dispatch.x_sendfile_header = 'X-Sendfile' # for Apache
  # config.action_dispatch.x_sendfile_header = 'X-Accel-Redirect' # for NGINX

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = ActiveModel::Type::Boolean.new.cast(ENV.fetch('FORCE_SSL', false))

  # customize using the environment variables
  config.log_level = ENV.fetch('LOG_LEVEL', 'info').to_sym

  # Prepend all log lines with the following tags.
  config.log_tags = [:request_id]

  # Cache em Redis (db 1, separado do Sidekiq em db 0) — compartilhado entre web+worker e
  # sobrevive ao redeploy. Reusa Redis::Config.app (url/ssl/senha/sentinels) e só troca o db.
  config.cache_store = :redis_cache_store, {
    **Redis::Config.app,
    db: 1,
    namespace: 'cache',
    expires_in: 1.day,
    pool: { size: ENV.fetch('RAILS_MAX_THREADS', 5).to_i, timeout: 1 },
    error_handler: lambda do |method:, returning:, exception:|
      Rails.logger.error("[cache] #{method} falhou (#{exception.class}: #{exception.message}); seguindo sem cache")
    end
  }

  # Use a real queuing backend for Active Job (and separate queues per environment)
  # config.active_job.queue_adapter     = :resque
  # config.active_job.queue_name_prefix = "chatwoot_#{Rails.env}"

  Rails.application.routes.default_url_options = { host: ENV['FRONTEND_URL'] }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = [I18n.default_locale]
  config.active_job.queue_adapter = :sidekiq

  # Send deprecation notices to registered listeners.
  config.active_support.deprecation = :notify

  # Use default logging formatter so that PID and timestamp are not suppressed.
  config.log_formatter = ::Logger::Formatter.new

  # Use a different logger for distributed setups.
  # require 'syslog/logger'
  config.logger = ActiveSupport::Logger.new(Rails.root.join("log/#{Rails.env}.log"), 1, ENV.fetch('LOG_SIZE', '1024').to_i.megabytes)

  if ActiveModel::Type::Boolean.new.cast(ENV.fetch('RAILS_LOG_TO_STDOUT', true))
    logger           = ActiveSupport::Logger.new($stdout)
    logger.formatter = config.log_formatter
    config.logger = ActiveSupport::TaggedLogging.new(logger)
  end

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false
end
