require 'active_support/ordered_options'

module Rails
  # Create a Plugin::Options from ActiveSuppot::OrderedOptions,
  # which support the following syntax:
  #
  #   controller.action_controller.include FooBar
  #
  class Plugin::Options < ActiveSupport::OrderedOptions #:nodoc:
    attr_reader :includes

    def initialize(*args)
      @includes = []
      super
    end

    def include(*args)
      @includes.concat(args)
    end
  end

  # Temporarily separate the plugin configuration class from the main
  # configuration class while this bit is being cleaned up.
  class Plugin::Configuration

    def self.default
      @default ||= new
    end

    attr_reader :middleware

    def initialize(base = nil)
      if base
        @options    = base.options.dup
        @middleware = base.middleware.dup
      else
        @options    = Hash.new { |h,k| h[k] = Rails::Plugin::Options.new }
        @middleware = ActionDispatch::MiddlewareStack.new
      end
    end

    def respond_to?(name)
      super || name.to_s =~ config_key_regexp
    end

  protected

    attr_reader :options

  private

    def method_missing(name, *args, &blk)
      if name.to_s =~ config_key_regexp
        return $2 == '=' ? @options[$1] = args.first : @options[$1]
      end

      super
    end

    def config_key_regexp
      bits = config_keys.map { |n| Regexp.escape(n.to_s) }.join('|')
      /^(#{bits})(?:=)?$/
    end

    def config_keys
      ([ :active_support, :action_view, :action_mailer, :active_resource ] +
        Plugin.plugin_names).map { |n| n.to_s }.uniq
    end
  end

  class Configuration < Plugin::Configuration
    attr_accessor :after_initialize_blocks, :cache_classes,
                  :consider_all_requests_local, :dependency_loading, :gems,
                  :load_once_paths, :logger, :metals, :plugins,
                  :preload_frameworks, :reload_plugins, :serve_static_assets,
                  :time_zone, :whiny_nils

    attr_writer :cache_store, :controller_paths,
                :database_configuration_file, :eager_load_paths,
                :frameworks, :framework_root_path, :i18n, :load_paths,
                :log_level, :log_path, :paths, :routes_configuration_file,
                :view_path

    def initialize(base = nil)
      super
      @load_once_paths              = []
      @after_initialize_blocks      = []
      @dependency_loading           = true
      @serve_static_assets          = true
    end

    def after_initialize(&blk)
      @after_initialize_blocks << blk if blk
    end

    def root
      @root ||= begin
        call_stack = caller.map { |p| p.split(':').first }
        root_path  = call_stack.detect { |p| p !~ %r[railties/lib/rails|rack/lib/rack] }
        root_path  = File.dirname(root_path)

        while root_path && File.directory?(root_path) && !File.exist?("#{root_path}/config.ru")
          parent = File.dirname(root_path)
          root_path = parent != root_path && parent
        end

        root = File.exist?("#{root_path}/config.ru") ? root_path : Dir.pwd

        RUBY_PLATFORM =~ /(:?mswin|mingw)/ ?
          Pathname.new(root).expand_path :
          Pathname.new(root).realpath
      end
    end

    def root=(root)
      @root = Pathname.new(root).expand_path
    end

    def paths
      @paths ||= begin
        paths = Rails::Application::Root.new(root)
        paths.app                 "app",             :load_path => true
        paths.app.metals          "app/metal",       :eager_load => true
        paths.app.models          "app/models",      :eager_load => true
        paths.app.controllers     "app/controllers", builtin_directories, :eager_load => true
        paths.app.helpers         "app/helpers",     :eager_load => true
        paths.app.services        "app/services",    :load_path => true
        paths.lib                 "lib",             :load_path => true
        paths.vendor              "vendor",          :load_path => true
        paths.vendor.plugins      "vendor/plugins"
        paths.tmp                 "tmp"
        paths.tmp.cache           "tmp/cache"
        paths.config              "config"
        paths.config.locales      "config/locales"
        paths.config.environments "config/environments", :glob => "#{RAILS_ENV}.rb"
        paths
      end
    end

    # Enable threaded mode. Allows concurrent requests to controller actions and
    # multiple database connections. Also disables automatic dependency loading
    # after boot, and disables reloading code on every request, as these are
    # fundamentally incompatible with thread safety.
    def threadsafe!
      self.preload_frameworks = true
      self.cache_classes = true
      self.dependency_loading = false

      if respond_to?(:action_controller)
        action_controller.allow_concurrency = true
      end
      self
    end

    def framework_paths
      paths = %w(railties railties/lib activesupport/lib)
      paths << 'actionpack/lib' if frameworks.include?(:action_controller) || frameworks.include?(:action_view)

      [:active_record, :action_mailer, :active_resource, :action_web_service].each do |framework|
        paths << "#{framework.to_s.gsub('_', '')}/lib" if frameworks.include?(framework)
      end

      paths.map { |dir| "#{framework_root_path}/#{dir}" }.select { |dir| File.directory?(dir) }
    end

    def framework_root_path
      defined?(::RAILS_FRAMEWORK_ROOT) ? ::RAILS_FRAMEWORK_ROOT : "#{root}/vendor/rails"
    end

    # Loads and returns the contents of the #database_configuration_file. The
    # contents of the file are processed via ERB before being sent through
    # YAML::load.
    def database_configuration
      require 'erb'
      YAML::load(ERB.new(IO.read(database_configuration_file)).result)
    end

    def routes_configuration_file
      @routes_configuration_file ||= File.join(root, 'config', 'routes.rb')
    end

    def builtin_routes_configuration_file
      @builtin_routes_configuration_file ||= File.join(RAILTIES_PATH, 'builtin', 'routes.rb')
    end

    def controller_paths
      @controller_paths ||= begin
        paths = [File.join(root, 'app', 'controllers')]
        paths.concat builtin_directories
        paths
      end
    end

    def cache_store
      @cache_store ||= begin
        if File.exist?("#{root}/tmp/cache/")
          [ :file_store, "#{root}/tmp/cache/" ]
        else
          :memory_store
        end
      end
    end

    def database_configuration_file
      @database_configuration_file ||= File.join(root, 'config', 'database.yml')
    end

    def view_path
      @view_path ||= File.join(root, 'app', 'views')
    end

    def eager_load_paths
      @eager_load_paths ||= %w(
        app/metal
        app/models
        app/controllers
        app/helpers
      ).map { |dir| "#{root}/#{dir}" }.select { |dir| File.directory?(dir) }
    end

    def load_paths
      @load_paths ||= begin
        paths = []

        # Add the old mock paths only if the directories exists
        paths.concat(Dir["#{root}/test/mocks/#{RAILS_ENV}"]) if File.exists?("#{root}/test/mocks/#{RAILS_ENV}")

        # Add the app's controller directory
        paths.concat(Dir["#{root}/app/controllers/"])

        # Followed by the standard includes.
        paths.concat %w(
          app
          app/metal
          app/models
          app/controllers
          app/helpers
          app/services
          lib
          vendor
        ).map { |dir| "#{root}/#{dir}" }.select { |dir| File.directory?(dir) }

        paths.concat builtin_directories
      end
    end

    def builtin_directories
      # Include builtins only in the development environment.
      (RAILS_ENV == 'development') ? Dir["#{RAILTIES_PATH}/builtin/*/"] : []
    end

    def log_path
      @log_path ||= File.join(root, 'log', "#{RAILS_ENV}.log")
    end

    def log_level
      @log_level ||= RAILS_ENV == 'production' ? :info : :debug
    end

    def frameworks
      @frameworks ||= [ :active_record, :action_controller, :action_view, :action_mailer, :active_resource ]
    end

    def i18n
      @i18n ||= begin
        i18n = ActiveSupport::OrderedOptions.new
        i18n.load_path = []

        if File.exist?(File.join(root, 'config', 'locales'))
          i18n.load_path << Dir[File.join(root, 'config', 'locales', '*.{rb,yml}')]
          i18n.load_path.flatten!
        end

        i18n
      end
    end

    def environment_path
      "#{root}/config/environments/#{RAILS_ENV}.rb"
    end

    # Holds generators configuration:
    #
    #   config.generators do |g|
    #     g.orm             :datamapper, :migration => true
    #     g.template_engine :haml
    #     g.test_framework  :rspec
    #   end
    #
    # If you want to disable color in console, do:
    #
    #   config.generators.colorize_logging = false
    #
    def generators
      @generators ||= Generators.new
      if block_given?
        yield @generators
      else
        @generators
      end
    end

    # Allows Notifications queue to be modified.
    #
    #   config.notifications.queue = MyNewQueue.new
    #
    def notifications
      ActiveSupport::Notifications
    end

    class Generators #:nodoc:
      attr_accessor :aliases, :options, :colorize_logging

      def initialize
        @aliases = Hash.new { |h,k| h[k] = {} }
        @options = Hash.new { |h,k| h[k] = {} }
        @colorize_logging = true
      end

      def method_missing(method, *args)
        method = method.to_s.sub(/=$/, '').to_sym

        if method == :rails
          namespace, configuration = :rails, args.shift
        elsif args.first.is_a?(Hash)
          namespace, configuration = method, args.shift
        else
          namespace, configuration = args.shift, args.shift
          @options[:rails][method] = namespace
        end

        if configuration
          aliases = configuration.delete(:aliases)
          @aliases[namespace].merge!(aliases) if aliases
          @options[namespace].merge!(configuration)
        end
      end
    end
  end
end
