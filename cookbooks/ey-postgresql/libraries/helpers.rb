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
    #   explicit_pin    - When true the call site holds a pin that must be honoured
    #                     exactly: the install_version must be present in
    #                     known_versions. If it is absent, raise (loud failure is
    #                     better than silently drifting a pinned version).
    #                     When false (unpinned default attribute) fall back to the
    #                     newest patch available within the same major series.
    #   pin_source      - Human-readable description of what pinned the version,
    #                     used in the raise message so the failure names the actual
    #                     reason instead of guessing at one. Ignored unless
    #                     explicit_pin is true. See resolve_pg_version_pin, which
    #                     returns the matching explicit_pin/pin_source pair.
    #
    # NOTE: server_install.rb runs on every Chef converge for db/app roles, not only
    # on first boot -- so this is called on already-provisioned instances during a
    # routine reconverge, not just on fresh installs. The call site pins to the
    # version dpkg reports as installed whenever the postgresql package is already
    # present on the node, so a reconverge resolves to what is actually installed
    # and never silently swaps a running database's patch version. That also makes
    # the resolution stable: the fallback below can only fire on a genuinely fresh
    # install, and the version it picks becomes the installed version that pins
    # every subsequent converge. See resolve_pg_version_pin for the precedence.
    #
    # Version matching uses Gem::Version for component-wise ordering so that
    # "16.10" sorts newer than "16.4" (lexical order gets this wrong).
    # Series membership is determined by matching the leading components of each
    # known version against short_version (e.g. short_version "9.5" matches
    # "9.5.25" but NOT "9.6.24"; short_version "16" matches "16.4", "16.10").
    #
    # Returns the best available version string, or raises if none can be resolved.
    def resolve_pg_package_version(known_versions, install_version, short_version, explicit_pin: false,
                                   pin_source: "lock_version_file or EY_POSTGRES_VERSION")
      # Exact-match first: if the pinned patch is still present, use it verbatim
      # regardless of explicit_pin. This is the happy-path for current installs.
      exact = known_versions.find do |v|
        begin
          Gem::Version.new(v) == Gem::Version.new(install_version)
        rescue ArgumentError
          false
        end
      end
      return exact if exact

      if explicit_pin
        raise "Chef does not know about PostgreSQL version #{install_version} " \
              "(pinned by #{pin_source}). " \
              "Known versions for series #{short_version}: #{known_versions.uniq}. " \
              "Update the pin or contact support."
      end

      # Default-attribute pin: the pinned patch is absent — find the newest
      # available patch within the same major series.
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

      best = in_series.max_by do |v|
        begin
          Gem::Version.new(v)
        rescue ArgumentError
          Gem::Version.new("0")
        end
      end
      Chef::Log.warn(
        "ey-postgresql: pinned version #{install_version} is not available in the apt repo. " \
        "Falling back to newest available patch in series #{short_version}: #{best}. " \
        "Once installed, subsequent converges pin to that installed version rather than " \
        "re-running this fallback. To suppress this warning, update attributes/version.rb."
      )
      best
    end

    # Decide which version this converge must resolve to, and why.
    #
    # Returns [install_version, explicit_pin, pin_source] for
    # resolve_pg_package_version. Precedence, strongest pin first:
    #
    #   1. lock_version_file  - customer enabled lock_db_version; the file holds
    #                           the exact running version and is authoritative.
    #   2. EY_POSTGRES_VERSION - explicit customer environment variable.
    #   3. installed package  - PostgreSQL is already installed on this node, so
    #                           the installed patch version IS the effective pin.
    #   4. default attribute  - unpinned; fall back to newest-in-series.
    #
    # Case 3 is what keeps a node stable across repeat converges. server_install.rb
    # runs on every converge (including the environment-wide runs triggered when an
    # instance is added or removed), so a node provisioned via the case-4 fallback
    # is reconverged with an installed version that no longer matches the default
    # attribute. Pinning to the *installed* version rather than to the stale
    # attribute means the guard compares against what is really on disk: the
    # already-installed patch matches exactly, the converge proceeds, and the
    # running database's version is still never swapped automatically.
    #
    # Comparing against the attribute instead would fail permanently -- the
    # fallback installs a version the attribute never named, so every converge
    # after the first would raise on a pin the node itself created.
    def resolve_pg_version_pin(node, short_version)
      if File.exist?(node["lock_version_file"])
        [File.read(node["lock_version_file"]).strip, true, "lock_version_file (#{node["lock_version_file"]})"]
      elsif !fetch_env_var(node, "EY_POSTGRES_VERSION").nil?
        [node["postgresql"]["latest_version"], true, "the EY_POSTGRES_VERSION environment variable"]
      elsif (installed = installed_pg_version(short_version))
        [installed, true, "the PostgreSQL #{installed} packages already installed on this instance"]
      else
        [node["postgresql"]["latest_version"], false, nil]
      end
    end

    # True if dpkg has any record of package_name being installed (dpkg
    # states "ii" and "rc" both exit 0; "rc" -- removed but not purged --
    # is a rare, fail-closed-only false positive, never a false negative).
    # Split out from pg_already_installed? so it can be exercised directly
    # against a real, always-present system package in tests, without
    # requiring PostgreSQL itself to be installed.
    def dpkg_package_installed?(package_name)
      system("dpkg-query -W #{package_name} >/dev/null 2>&1")
    end

    # Returns true if the postgresql-{short_version} package is already
    # installed on this node according to dpkg. Works on both DB-tier nodes
    # (which run a full server) and app-tier nodes (which also receive the
    # full postgresql-{version} server package unconditionally from
    # install.sh.erb). Unlike pg_running (which shells out to psql -h
    # localhost and is structurally always false on app-tier nodes, which
    # never expose a local Postgres socket), this check is role-agnostic.
    #
    # Returns false on a genuinely fresh node (package not yet installed),
    # which is the only case where fallback-to-newest-in-series is safe.
    def pg_already_installed?(short_version)
      dpkg_package_installed?("postgresql-#{short_version}")
    end

    # The upstream version of an installed package as dpkg reports it, with the
    # debian revision stripped: "11.22-10.pgdg24.04+1" -> "11.22". Returns nil
    # if the package is not installed, or if dpkg reports a version that does
    # not start with a dotted numeric version (nothing to pin to).
    #
    # Two dpkg version details this has to survive, because a version parsed
    # wrong becomes a pin that can never match:
    #   - An epoch prefix ("1:2.39.3-9") is dpkg-internal ordering metadata and
    #     is not part of the upstream version, so strip it. PostgreSQL's
    #     packages carry no epoch today, but reading one as the version would
    #     silently pin to the epoch number.
    #   - dpkg-query exits 0 for the "rc" state (removed but config files
    #     remain), where Version is still populated even though no server is
    #     installed -- so filter on the install state rather than the exit
    #     status, and treat a removed-but-not-purged instance as fresh.
    def dpkg_package_version(package_name)
      out = `dpkg-query -W -f='${db:Status-Status} ${Version}' #{package_name} 2>/dev/null`.strip
      status, version = out.split(" ", 2)
      return nil unless status == "installed" && version
      version.sub(/\A[0-9]+:/, "")[/\A[0-9]+(\.[0-9]+)*/]
    end

    # The PostgreSQL patch version currently installed on this node, e.g.
    # "11.22", or nil on a genuinely fresh node. Reads the same
    # postgresql-{short_version} server package that pg_already_installed?
    # checks -- install.sh.erb installs it unconditionally on both the DB and
    # app tiers, so this is a valid already-provisioned signal for either.
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
