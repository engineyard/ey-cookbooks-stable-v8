module PostgreSQL
  module Helper
    # Resolve a PostgreSQL package version from the list of versions advertised
    # by apt-cache madison.
    #
    # Parameters:
    #   known_versions  - Array of dotted version strings, e.g. ["16.15", "16.14", "16.4"]
    #                     (already stripped of the "-1.pgdg…" debian suffix by the caller)
    #   install_version - The version string from node["postgresql"]["latest_version"],
    #                     e.g. "16.4" or "9.5.25".
    #   short_version   - node["postgresql"]["short_version"], e.g. "16" or "9.5".
    #                     Used to identify the series when falling back to newest.
    #   pin             - Where the requested version came from, which decides what
    #                     happens when it is not available. See resolve_pg_version_pin,
    #                     which returns the matching pin/pin_source pair.
    #
    #                     :human     a person pinned this version deliberately (a
    #                                lock version file, or EY_POSTGRES_VERSION).
    #                                It must be honoured exactly; if it is absent,
    #                                raise, because quietly installing something
    #                                else would defeat the pin.
    #                     :installed the version already installed on this instance
    #                                pinned itself. Honour it exactly when it is
    #                                still available -- the common case, and the one
    #                                that keeps a running database's patch version
    #                                from moving. When the repository no longer
    #                                offers it, move to the CLOSEST available patch
    #                                in the same series and say so loudly, rather
    #                                than failing every converge on an instance
    #                                whose only problem is that the repository moved
    #                                underneath it.
    #                     :none      nothing pins this version (the default
    #                                attribute for a fresh install). Fall back to
    #                                the newest patch available in the same series.
    #   pin_source      - Human-readable description of what pinned the version,
    #                     used in the raise message so the failure names the actual
    #                     reason instead of guessing at one. Used only when pin is
    #                     :human.
    #
    # NOTE: server_install.rb runs on every Chef converge for db/app roles, not only
    # on first boot -- so this is called on already-provisioned instances during a
    # routine reconverge, not just on fresh installs. The call site pins to the
    # version dpkg reports as installed whenever the postgresql package is already
    # present on the node, so a reconverge resolves to what is actually installed
    # and does not move a running database's patch version. That also makes the
    # resolution stable: the newest-in-series fallback can only fire on a genuinely
    # fresh install, and the version it picks becomes the installed version that
    # pins every subsequent converge. See resolve_pg_version_pin for the precedence.
    #
    # The one case where an installed version does move is when the repository has
    # stopped offering it -- the same pruning this whole helper exists to survive.
    # Nothing can reinstall a package that is no longer published, so the choice is
    # between the closest available patch and refusing to converge at all; this
    # takes the closest patch and logs a warning naming both versions, so the move
    # is recorded rather than silent.
    #
    # Version matching uses Gem::Version for component-wise ordering so that
    # "16.10" sorts newer than "16.4" (lexical order gets this wrong).
    # Series membership is determined by matching the leading components of each
    # known version against short_version (e.g. short_version "9.5" matches
    # "9.5.25" but NOT "9.6.24"; short_version "16" matches "16.4", "16.10").
    #
    # Returns the best available version string, or raises if none can be resolved.
    PIN_KINDS = %i[human installed none].freeze

    DEFAULT_PIN_SOURCES = {
      human: "lock_version_file or EY_POSTGRES_VERSION",
      installed: "the PostgreSQL packages already installed on this instance",
      none: "the default attribute for the PostgreSQL series",
    }.freeze

    def resolve_pg_package_version(known_versions, install_version, short_version, pin: :none,
                                   pin_source: nil)
      unless PIN_KINDS.include?(pin)
        raise ArgumentError, "unknown pin kind #{pin.inspect} (expected one of #{PIN_KINDS.inspect})"
      end
      pin_source ||= DEFAULT_PIN_SOURCES[pin]

      # Exact-match first: if the requested patch is still published, use it
      # verbatim whatever pinned it. This is the happy path for every converge
      # of an instance whose version is still in the repository.
      exact = known_versions.find do |v|
        begin
          Gem::Version.new(v) == Gem::Version.new(install_version)
        rescue ArgumentError
          false
        end
      end
      if exact
        # Record the decision even on the happy path. The two paths below warn
        # for themselves; without this line the most consequential outcome --
        # "this instance stays on the version it already has" -- is the one
        # outcome that leaves no trace, so an operator rolling out a newer patch
        # build cannot tell from the converge log that it was not applied.
        Chef::Log.info(
          "ey-postgresql: resolved PostgreSQL #{exact} for series #{short_version} " \
          "(requested #{install_version}, pinned by #{pin_source})."
        )
        return exact
      end

      # A version a person pinned deliberately is the one case where refusing to
      # converge is right: installing something other than what was asked for is
      # precisely what the pin exists to prevent.
      if pin == :human
        raise "Chef does not know about PostgreSQL version #{install_version} " \
              "(pinned by #{pin_source}). " \
              "Known versions for series #{short_version}: #{known_versions.uniq}. " \
              "Update the pin or contact support."
      end

      best = newest_pg_version_in_series(known_versions, install_version, short_version)

      if pin == :installed
        # The installed version is no longer published, so it cannot be
        # reinstalled and the exact match above can never succeed again. Raising
        # here would wedge every converge on an instance that is running fine and
        # whose only problem is that the repository moved. Move to the newest
        # published patch in the same series instead -- a patch-level move within
        # one major series, which is what upstream recommends running anyway --
        # and name both versions so the move is on the record.
        Chef::Log.warn(
          "ey-postgresql: PostgreSQL #{install_version} is installed on this instance but is no " \
          "longer published in the apt repository, so it cannot be reinstalled. Moving to the " \
          "newest patch still published in series #{short_version}: #{best}. This is a patch-level " \
          "move within the same major series and does not change the data directory format. To hold " \
          "one specific patch version instead, enable lock_db_version or set EY_POSTGRES_VERSION."
        )
      else
        Chef::Log.warn(
          "ey-postgresql: pinned version #{install_version} is not available in the apt repo. " \
          "Falling back to newest available patch in series #{short_version}: #{best}. " \
          "Once installed, subsequent converges pin to that installed version rather than " \
          "re-running this fallback. To suppress this warning, update attributes/version.rb."
        )
      end
      best
    end

    # The newest published patch within install_version's major series, or raise
    # when the series has no packages at all (nothing to install, at any version).
    def newest_pg_version_in_series(known_versions, install_version, short_version)
      short_components = short_version.split(".")
      n = short_components.length

      in_series = known_versions.select do |v|
        v.split(".").first(n) == short_components
      end

      if in_series.empty?
        raise "Chef cannot resolve a PostgreSQL package for version #{install_version} " \
              "(fallback: no packages found in series #{short_version}). " \
              "Known versions: #{known_versions.uniq}. Contact support."
      end

      in_series.max_by do |v|
        begin
          Gem::Version.new(v)
        rescue ArgumentError
          Gem::Version.new("0")
        end
      end
    end

    # Decide which version this converge must resolve to, and why.
    #
    # Returns [install_version, pin, pin_source] for resolve_pg_package_version.
    # `pin` is one of :human, :installed, :none. Precedence, strongest first:
    #
    #   1. lock_version_file   (:human)     - customer enabled lock_db_version;
    #                                          the file holds the exact running
    #                                          version and is authoritative.
    #   2. EY_POSTGRES_VERSION (:human)     - explicit customer environment variable.
    #   3. installed package   (:installed) - PostgreSQL is already installed on
    #                                          this node, so the installed patch
    #                                          version IS the effective pin.
    #   4. default attribute   (:none)      - unpinned; fall back to newest-in-series.
    #
    # Case 3 is what keeps a node stable across repeat converges. server_install.rb
    # runs on every converge (including the environment-wide runs triggered when an
    # instance is added or removed), so a node provisioned via the case-4 fallback
    # is reconverged with an installed version that no longer matches the default
    # attribute. Pinning to the *installed* version rather than to the stale
    # attribute means the guard compares against what is really on disk: the
    # already-installed patch matches exactly and the converge proceeds without
    # moving the running database's version.
    #
    # Comparing against the attribute instead would fail permanently -- the
    # fallback installs a version the attribute never named, so every converge
    # after the first would raise on a pin the node itself created.
    #
    # The distinction between :human and :installed is what resolve_pg_package_version
    # keys on when the requested version is no longer published: a human pin is
    # honoured or the run fails; an installed-version pin moves to the closest
    # published patch in the series (see that method). Both hold the same property
    # for the common case -- an available installed version is never swapped on a
    # routine converge. See PATCH DELIVERY below.
    #
    # PATCH DELIVERY (how a newer patch build reaches instances):
    #   - Fresh installs pick up the newest published patch in the series
    #     immediately, via the :none fallback.
    #   - An already-provisioned instance intentionally stays on its installed
    #     patch as long as that patch is still published -- a routine Chef Apply
    #     must not restart-and-move a customer's running database as a side
    #     effect. It moves forward when EITHER the installed patch is pruned from
    #     the repository (the :installed path moves to the newest in series) OR an
    #     operator sets an explicit pin (lock_version_file / EY_POSTGRES_VERSION)
    #     to the desired patch, which is honoured exactly. A bare attribute bump
    #     in attributes/version.rb therefore does NOT move existing instances by
    #     itself; it changes only what a fresh install resolves to.
    def resolve_pg_version_pin(node, short_version)
      if File.exist?(node["lock_version_file"])
        [File.read(node["lock_version_file"]).strip, :human, "lock_version_file (#{node["lock_version_file"]})"]
      elsif !fetch_env_var(node, "EY_POSTGRES_VERSION").nil?
        [node["postgresql"]["latest_version"], :human, "the EY_POSTGRES_VERSION environment variable"]
      elsif (installed = installed_pg_version(short_version))
        [installed, :installed, "the PostgreSQL #{installed} packages already installed on this instance"]
      else
        [node["postgresql"]["latest_version"], :none, "the default attribute for the PostgreSQL series"]
      end
    end

    # The upstream version of an installed package as dpkg reports it, with the
    # debian revision stripped: "11.22-10.pgdg24.04+1" -> "11.22". Returns nil
    # if the package is not installed, or if dpkg reports a version that does
    # not start with a dotted numeric version (nothing to pin to).
    #
    # Two dpkg details this has to survive, because both decide whether an
    # instance is treated as already-provisioned or as fresh:
    #   - An epoch prefix ("1:2.39.3-9") is dpkg-internal ordering metadata and
    #     is not part of the upstream version, so strip it. PostgreSQL's
    #     packages carry no epoch today, but reading one as the version would
    #     silently pin to the epoch number -- a pin that can never match.
    #   - dpkg-query exits 0 for states where no package is on disk, so filter
    #     on the install state rather than the exit status. Only two states
    #     mean "nothing installed": "not-installed", and "config-files" (the
    #     package was removed without being purged, so only its conffiles
    #     remain). Every other state -- "installed", but also "unpacked" and
    #     the half-configured/triggers states an interrupted converge leaves
    #     behind -- means the package files ARE on disk and the version dpkg
    #     reports is the one this instance is running.
    #
    # That distinction has to be exact, because the two ways of being wrong are
    # not equally bad. Reading a present package as absent makes the caller
    # treat a provisioned instance as fresh, which lets the newest-in-series
    # fallback swap a running database's patch version -- silently, since the
    # install script allows downgrades. Reading an absent package as present
    # can at worst raise, which is loud and recoverable. So when a state is
    # ambiguous, treat the package as present.
    PACKAGE_ABSENT_STATES = %w[not-installed config-files].freeze

    def dpkg_package_version(package_name)
      out = `dpkg-query -W -f='${db:Status-Status} ${Version}' #{package_name} 2>/dev/null`.strip
      status, version = out.split(" ", 2)
      return nil if status.nil? || version.nil?
      return nil if PACKAGE_ABSENT_STATES.include?(status)
      version.sub(/\A[0-9]+:/, "")[/\A[0-9]+(\.[0-9]+)*/]
    end

    # The PostgreSQL patch version currently installed on this node, e.g.
    # "11.22", or nil on a genuinely fresh node -- which is the only case
    # where falling back to the newest patch in the series is safe.
    #
    # Reads the postgresql-{short_version} server package, which install.sh.erb
    # installs unconditionally on both the DB and app tiers, so this is a valid
    # already-provisioned signal for either. Unlike pg_running (which shells out
    # to psql -h localhost and is structurally always false on app-tier nodes,
    # which never expose a local Postgres socket), it is role-agnostic, and it
    # needs no PostgreSQL binary or socket to exist yet.
    def installed_pg_version(short_version)
      dpkg_package_version("postgresql-#{short_version}")
    end

    def lock_db_version
      node.engineyard.environment.lock_db_version? ? node.engineyard.environment.components.find_all { |e| e["key"] == "lock_db_version" }.first["value"] : false
    end

    def pg_running
      `psql -U #{node.engineyard.environment["db_admin_username"]} -t -h localhost -c"select 1;" 2> /dev/null`.strip == "1"
    end

    def running_pg_version
      if pg_running
        `psql -U #{node.engineyard.environment["db_admin_username"]} -c'select version();' | grep -E -o 'PostgreSQL ([0-9]+\.?)+' | awk '{print $NF}'`.strip
      else
        binary_pg_version
      end
    end

    def binary_pg_version
      `psql -U #{node.engineyard.environment["db_admin_username"]} --version | grep -E -o '\(PostgreSQL\) ([0-9]+\.?)+' | awk '{print $NF}'`.strip
    end

    def add_shared_preload_library(lib)
      custom_conf = "/db/postgresql/#{node['postgresql']['short_version']}/custom.conf"
      body = File.read(custom_conf)
      return if body[/shared_preload_libraries.*#{lib}/]
      if body[/shared_preload_libraries/]
        body.gsub!(/^(shared_preload_libraries.*'?)(.*?)('.*)$/, '\1\2,' + lib + '\3')
        File.write(custom_conf, body)
      else
        `echo "shared_preload_libraries = '#{lib}'" >> #{custom_conf}`
      end
    end

    def postgres_version_cmp(lhs_version, rhs_version)
      lhs_version_components = lhs_version.split(".").map(&:to_i)
      rhs_version_components = rhs_version.split(".").map(&:to_i)
      lhs_version_components <=> rhs_version_components
    end

    def postgres_version_gte?(compare_version)
      postgres_version_cmp(node["postgresql"]["short_version"], compare_version) >= 0
    end

    def postgres_version_gt?(compare_version)
      postgres_version_cmp(node["postgresql"]["short_version"], compare_version) > 0
    end

    def postgres_version_lt?(compare_version)
      !postgres_version_gte?(compare_version)
    end
  end
end

Chef::DSL::Recipe.send(:include, PostgreSQL::Helper)
Chef::Resource.send(:include, PostgreSQL::Helper)
