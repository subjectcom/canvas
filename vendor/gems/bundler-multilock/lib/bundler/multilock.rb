# frozen_string_literal: true

require_relative "multilock/ext/bundler"
require_relative "multilock/ext/definition"
require_relative "multilock/ext/dsl"
require_relative "multilock/ext/plugin"
require_relative "multilock/ext/plugin/dsl"
require_relative "multilock/ext/shared_helpers"
require_relative "multilock/ext/source"
require_relative "multilock/ext/source_list"
require_relative "multilock/version"

module Bundler
  module Multilock
    class << self
      # @!visibility private
      attr_reader :lockfile_definitions
      # @!visibility private
      attr_accessor :prepare_block

      # @param lockfile [String] The lockfile path (defaults to Gemfile.lock)
      # @param builder [Dsl] The Bundler DSL
      # @param gemfile [String, nil]
      #   The Gemfile for this lockfile (defaults to Gemfile)
      # @param active [Boolean]
      #   If this lockfile should be the default (instead of Gemfile.lock)
      #   BUNDLE_LOCKFILE will still override a lockfile tagged as active
      # @param parent [String] The parent lockfile to sync dependencies from.
      #   Also used for comparing enforce_pinned_additional_dependencies against.
      # @param allow_mismatched_dependencies [true, false]
      #   Allows version differences in dependencies between this lockfile and
      #   the default lockfile. Note that even with this option, only top-level
      #   dependencies that differ from the default lockfile, and their transitive
      #   depedencies, are allowed to mismatch.
      # @param enforce_pinned_additional_dependencies [true, false]
      #   If dependencies are present in this lockfile that are not present in the
      #   default lockfile, enforce that they are pinned.
      # @yield
      #   Block executed only when this lockfile is active.
      # @return [true, false] if the lockfile is the active lockfile
      def add_lockfile(lockfile = nil,
                       builder:,
                       gemfile: nil,
                       active: nil,
                       default: nil,
                       parent: nil,
                       allow_mismatched_dependencies: true,
                       enforce_pinned_additional_dependencies: false,
                       &block)
        # backcompat
        active = default if active.nil?
        Bundler.ui.warn("lockfile(default:) is deprecated. Use lockfile(active:) instead.") if default

        active = true if active.nil? && lockfile_definitions.empty? && lockfile.nil? && gemfile.nil?

        # if a gemfile was provided, but not a lockfile, infer the default lockfile for that gemfile
        lockfile ||= "#{gemfile}.lock" if gemfile
        # allow short-form lockfile names
        lockfile = expand_lockfile(lockfile)

        if lockfile_definitions.find { |definition|  definition[:lockfile] == lockfile }
          raise ArgumentError, "Lockfile #{lockfile} is already defined"
        end

        env_lockfile = ENV["BUNDLE_LOCKFILE"]&.then { |l| expand_lockfile(l) }
        active = env_lockfile == lockfile if env_lockfile

        if active && (old_active = lockfile_definitions.find { |definition| definition[:active] })
          raise ArgumentError, "Only one lockfile (#{old_active[:lockfile]}) can be flagged as the default"
        end

        parent = expand_lockfile(parent)
        if parent != Bundler.default_lockfile(force_original: true) &&
           !lockfile_definitions.find { |definition| definition[:lockfile] == parent }
          raise ArgumentError, "Parent lockfile #{parent} is not defined"
        end

        lockfile_definitions << (lockfile_def = {
          gemfile: (gemfile && Bundler.root.join(gemfile).expand_path) || Bundler.default_gemfile,
          lockfile: lockfile,
          active: active,
          prepare: block,
          parent: parent,
          allow_mismatched_dependencies: allow_mismatched_dependencies,
          enforce_pinned_additional_dependencies: enforce_pinned_additional_dependencies
        })

        if (defined?(CLI::Check) ||
            defined?(CLI::Install) ||
            defined?(CLI::Lock) ||
            defined?(CLI::Update)) &&
           !defined?(CLI::Cache) && !env_lockfile
          # always use Gemfile.lock for `bundle check`, `bundle install`,
          # `bundle lock`, and `bundle update`. `bundle cache` delegates to
          # `bundle install`, but we want that to run as normal.
          # If they're using BUNDLE_LOCKFILE, then they really do want to
          # use a particular lockfile, and it overrides whatever they
          # dynamically set in their gemfile
          active = lockfile == Bundler.default_lockfile(force_original: true)
        end

        if active
          block&.call
          Bundler.default_lockfile = lockfile

          # we started evaluating the project's primary gemfile, but got told to use a lockfile
          # associated with a different Gemfile. so we need to evaluate that Gemfile instead
          if lockfile_def[:gemfile] != Bundler.default_gemfile
            # share a cache between all lockfiles
            Bundler.cache_root = Bundler.root
            ENV["BUNDLE_GEMFILE"] = lockfile_def[:gemfile].to_s
            Bundler.root = Bundler.default_gemfile.dirname
            Bundler.default_lockfile = lockfile

            builder.eval_gemfile(Bundler.default_gemfile)

            return false
          end
        end
        true
      end

      # @!visibility private
      def after_install_all(install: true)
        loaded!
        previous_recursive = @recursive

        return if lockfile_definitions.empty?
        return if ENV["BUNDLE_LOCKFILE"] # explicitly working against a single lockfile

        # must be running `bundle cache`
        return unless Bundler.default_lockfile == Bundler.default_lockfile(force_original: true)

        require_relative "multilock/check"

        if Bundler.frozen_bundle? && !install
          # only do the checks if we're frozen
          exit 1 unless Check.run
          return
        end

        # this hook will be called recursively when it has to install gems
        # for a secondary lockfile. defend against that
        return if @recursive

        @recursive = true

        require "tempfile"
        require_relative "multilock/lockfile_generator"

        Bundler.ui.debug("Syncing to alternate lockfiles")
        Bundler.ui.info ""

        attempts = 1

        default_root = Bundler.root

        checker = Check.new
        synced_any = false
        Bundler.settings.temporary(cache_all_platforms: true, suppress_install_using_messages: true) do
          lockfile_definitions.each do |lockfile_definition|
            # we already wrote the default lockfile
            next if lockfile_definition[:lockfile] == Bundler.default_lockfile(force_original: true)

            # root needs to be set so that paths are output relative to the correct root in the lockfile
            Bundler.root = lockfile_definition[:gemfile].dirname

            relative_lockfile = lockfile_definition[:lockfile].relative_path_from(Dir.pwd)

            # already up to date?
            up_to_date = false
            Bundler.settings.temporary(frozen: true) do
              Bundler.ui.silence do
                up_to_date = checker.base_check(lockfile_definition) &&
                             checker.check(lockfile_definition, allow_mismatched_dependencies: false)
              end
            end
            if up_to_date
              attempts = 1
              next
            end

            if Bundler.frozen_bundle?
              # if we're frozen, you have to use the pre-existing lockfile
              unless lockfile_definition[:lockfile].exist?
                Bundler.ui.error("The bundle is locked, but #{relative_lockfile} is missing. " \
                                 "Please make sure you have checked #{relative_lockfile} " \
                                 "into version control before deploying.")
                exit 1
              end

              Bundler.ui.info("Installing gems for #{relative_lockfile}...")
              write_lockfile(lockfile_definition, lockfile_definition[:lockfile], install: install)
            else
              Bundler.ui.info("Syncing to #{relative_lockfile}...") if attempts == 1
              synced_any = true

              parent = lockfile_definition[:parent]
              parent_root = parent.dirname
              checker.load_lockfile(parent)
              parent_specs = checker.lockfile_specs[parent]

              # adjust locked paths from the parent lockfile to be relative to _this_ gemfile
              adjusted_parent_lockfile_contents =
                checker.lockfile_contents[parent].gsub(/PATH\n  remote: ([^\n]+)\n/) do |remote|
                  remote_path = Pathname.new($1)
                  next remote if remote_path.absolute?

                  relative_remote_path = remote_path.expand_path(parent_root).relative_path_from(Bundler.root).to_s
                  remote.sub($1, relative_remote_path)
                end

              # add a source for the current gem
              gem_spec = parent_specs[[File.basename(Bundler.root), "ruby"]]

              if gem_spec
                adjusted_parent_lockfile_contents += <<~TEXT
                  PATH
                    remote: .
                    specs:
                  #{gem_spec.to_lock}
                TEXT
              end

              if lockfile_definition[:lockfile].exist?
                # if the lockfile already exists, "merge" it together
                parent_lockfile = LockfileParser.new(adjusted_parent_lockfile_contents)
                lockfile = LockfileParser.new(lockfile_definition[:lockfile].read)

                dependency_changes = false
                # replace any duplicate specs with what's in the default lockfile
                lockfile.specs.map! do |spec|
                  parent_spec = parent_specs[[spec.name, spec.platform]]
                  next spec unless parent_spec

                  dependency_changes ||= spec != parent_spec
                  parent_spec
                end

                lockfile.specs.replace(parent_lockfile.specs + lockfile.specs).uniq!
                lockfile.sources.replace(parent_lockfile.sources + lockfile.sources).uniq!
                lockfile.platforms.replace(parent_lockfile.platforms).uniq!
                # prune more specific platforms
                lockfile.platforms.delete_if do |p1|
                  lockfile.platforms.any? do |p2|
                    p2 != "ruby" && p1 != p2 && MatchPlatform.platforms_match?(p2, p1)
                  end
                end
                lockfile.instance_variable_set(:@ruby_version, parent_lockfile.ruby_version)
                unless lockfile.bundler_version == parent_lockfile.bundler_version
                  unlocking_bundler = true
                  lockfile.instance_variable_set(:@bundler_version, parent_lockfile.bundler_version)
                end

                new_contents = LockfileGenerator.generate(lockfile)
              else
                # no lockfile? just start out with the parent lockfile's contents to inherit its
                # locked gems
                new_contents = adjusted_parent_lockfile_contents
              end

              had_changes = false
              # Now build a definition based on the given Gemfile, with the combined lockfile
              Tempfile.create do |temp_lockfile|
                temp_lockfile.write(new_contents)
                temp_lockfile.flush

                had_changes = write_lockfile(lockfile_definition,
                                             temp_lockfile.path,
                                             install: install,
                                             dependency_changes: dependency_changes,
                                             unlocking_bundler: unlocking_bundler)
              end

              # if we had changes, bundler may have updated some common
              # dependencies beyond the default lockfile, so re-run it
              # once to reset them back to the default lockfile's version.
              # if it's already good, the `check` check at the beginning of
              # the loop will skip the second sync anyway.
              if had_changes && attempts < 2
                attempts += 1
                Bundler.ui.debug("Re-running sync to #{relative_lockfile} to reset common dependencies")
                redo
              else
                attempts = 1
              end
            end
          end
        ensure
          Bundler.root = default_root
        end

        exit 1 unless checker.run(skip_base_checks: !synced_any)
      ensure
        @recursive = previous_recursive
      end

      # @!visibility private
      def loaded!
        return if loaded?

        @loaded = true
        return if lockfile_definitions.empty?

        return unless lockfile_definitions.none? { |definition| definition[:active] }

        if ENV["BUNDLE_LOCKFILE"]&.then { |l| expand_lockfile(l) } ==
           Bundler.default_lockfile(force_original: true)
          return
        end

        raise GemfileNotFound, "Could not locate lockfile #{ENV["BUNDLE_LOCKFILE"].inspect}" if ENV["BUNDLE_LOCKFILE"]

        # Gemfile.lock isn't explicitly specified, otherwise it would be active
        default_lockfile_definition = lockfile_definitions.find do |definition|
          definition[:lockfile] == Bundler.default_lockfile(force_original: true)
        end
        return unless default_lockfile_definition && default_lockfile_definition[:active] == false

        raise GemfileEvalError, "No lockfiles marked as default"
      end

      # @!visibility private
      def loaded?
        @loaded
      end

      # @!visibility private
      def inject_preamble
        Bundler.ui.debug("Injecting multilock preamble")

        minor_version = Gem::Version.new(::Bundler::Multilock::VERSION).segments[0..1].join(".")
        bundle_preamble1_match = /plugin ["']bundler-multilock["']/
        bundle_preamble1 = <<~RUBY
          plugin "bundler-multilock", "~> #{minor_version}"
        RUBY
        bundle_preamble2 = <<~RUBY
          return unless Plugin.installed?("bundler-multilock")

          Plugin.send(:load_plugin, "bundler-multilock")
        RUBY

        gemfile = Bundler.default_gemfile.read

        injection_point = 0
        while gemfile.match?(/^(?:#|\n|source)/, injection_point)
          if gemfile[injection_point] == "\n"
            injection_point += 1
          else
            injection_point = gemfile.index("\n", injection_point)
            injection_point += 1 if injection_point
            injection_point ||= -1
          end
        end

        builder = Bundler::Plugin::DSL.new
        # this method is called as part of the plugin loading, but @loaded_plugin_names
        # hasn't been set yet, so avoid re-entrancy issues
        plugins = Bundler::Plugin.instance_variable_get(:@loaded_plugin_names)
        original_plugins = plugins.dup
        plugins << "bundler-multilock"
        begin
          builder.eval_gemfile(Bundler.default_gemfile)
        ensure
          plugins.replace(original_plugins)
        end
        gemfiles = builder.instance_variable_get(:@gemfiles).map(&:read)

        modified = inject_specific_preamble(gemfile, gemfiles, injection_point, bundle_preamble2, add_newline: true)
        modified = true if inject_specific_preamble(gemfile,
                                                    gemfiles,
                                                    injection_point,
                                                    bundle_preamble1,
                                                    match: bundle_preamble1_match,
                                                    add_newline: false)

        Bundler.default_gemfile.write(gemfile) if modified
      end

      # @!visibility private
      def reset!
        @lockfile_definitions = []
        @loaded = false
      end

      private

      def expand_lockfile(lockfile)
        if lockfile.is_a?(String) && !(lockfile.include?("/") || lockfile.end_with?(".lock"))
          lockfile = "Gemfile.#{lockfile}.lock"
        end
        # use absolute paths
        lockfile = Bundler.root.join(lockfile).expand_path if lockfile
        # use the default lockfile (Gemfile.lock) if none was given
        lockfile || Bundler.default_lockfile(force_original: true)
      end

      def inject_specific_preamble(gemfile, gemfiles, injection_point, preamble, add_newline:, match: nil)
        # allow either type of quotes
        match ||= Regexp.new(Regexp.escape(preamble).gsub('"', %(["'])))
        return false if gemfiles.any? { |g| match.match?(g) }

        add_newline = false unless gemfile[injection_point - 1] == "\n"

        gemfile.insert(injection_point, "\n") if add_newline
        gemfile.insert(injection_point, preamble)

        true
      end

      def write_lockfile(lockfile_definition, lockfile, install:, dependency_changes: false, unlocking_bundler: false)
        prepare_block = lockfile_definition[:prepare]

        gemfile = lockfile_definition[:gemfile]
        # use avoid Definition.build, so that we don't have to evaluate
        # the gemfile multiple times, each time we need a separate definition
        builder = Dsl.new
        builder.eval_gemfile(gemfile, &prepare_block) if prepare_block
        builder.eval_gemfile(gemfile)

        definition = builder.to_definition(lockfile, { bundler: unlocking_bundler })
        definition.instance_variable_set(:@dependency_changes, dependency_changes) if dependency_changes

        current_lockfile = lockfile_definition[:lockfile]
        definition.instance_variable_set(:@lockfile_contents, current_lockfile.read) if current_lockfile.exist?

        orig_definition = definition.dup # we might need it twice

        if current_lockfile.exist? && install
          Bundler.settings.temporary(frozen: true) do
            current_definition = builder.to_definition(current_lockfile, {})
            current_definition.resolve_with_cache!
            if current_definition.missing_specs.any?
              Bundler.with_default_lockfile(current_lockfile) do
                Installer.install(gemfile.dirname, current_definition, {})
              end
            end
          rescue RubyVersionMismatch, GemNotFound, SolveFailure
            # ignore
          end
        end

        resolved_remotely = false
        accesses = begin
          previous_ui_level = Bundler.ui.level
          Bundler.ui.level = "warn"
          begin
            # this is a horrible hack, to fix what I consider to be a Bundler bug.
            # basically, if you have multiple platform specific gems in your
            # lockfile, and that gem gets unlocked, Bundler will only search
            # locally to find them. But non-platform-local gems are _never_
            # installed locally. So just find the non-platform-local gems
            # in the lockfile (that we know are there from a prior remote
            # resolution), and add them to the locally installed spec list.
            definition.send(:source_map).locked_specs.each do |spec|
              next if spec.match_platform(Bundler.local_platform)

              spec.source.specs << spec
            end
            definition.resolve_with_cache!
          rescue GemNotFound, SolveFailure
            definition = orig_definition

            definition.resolve_remotely!
            resolved_remotely = true
          end
          SharedHelpers.capture_filesystem_access do
            definition.lock(lockfile_definition[:lockfile], true)
          end
        ensure
          Bundler.ui.level = previous_ui_level
        end

        # if we're running `bundle install` or `bundle update`, and something is missing from
        # the secondary lockfile, install it.
        if install && (definition.missing_specs.any? || resolved_remotely)
          Bundler.with_default_lockfile(lockfile_definition[:lockfile]) do
            Installer.install(lockfile_definition[:gemfile].dirname, definition, {})
          end
        end

        accesses && !accesses.empty?
      end
    end

    reset!

    @recursive = false
    @prepare_block = nil
  end
end

Bundler::Multilock.inject_preamble unless Bundler::Multilock.loaded?

# this is terrible, but we can't prepend into these modules because we only load
# _inside_ of the CLI commands already running
if defined?(Bundler::CLI::Check)
  require_relative "multilock/check"
  at_exit do
    next unless $!.nil?
    next if $!.is_a?(SystemExit) && !$!.success?

    next if Bundler::Multilock::Check.run

    Bundler.ui.warn("You can attempt to fix by running `bundle install`")
    exit 1
  end
end
if defined?(Bundler::CLI::Lock)
  at_exit do
    next unless $!.nil?
    next if $!.is_a?(SystemExit) && !$!.success?

    Bundler::Multilock.after_install_all(install: false)
  end
end