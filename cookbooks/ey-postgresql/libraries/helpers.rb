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
    #   explicit_pin    - When true the call site holds a deliberate customer pin
    #                     (lock_version_file or EY_POSTGRES_VERSION env var) and
    #                     the exact install_version must be present in known_versions.
    #                     If it is absent, raise (loud failure is better than silently
    #                     drifting a pin the customer deliberately set).
    #                     When false (default attribute pin) fall back to the newest
    #                     patch available within the same major series.
    #
    # NOTE: server_install.rb runs on every Chef converge for db/app roles, not only
    # on first boot -- so the fallback path can fire on an already-provisioned
    # instance during a routine reconverge, not just a fresh install. The call
    # site treats "the postgresql package is already installed on this node"
    # (checked via dpkg-query, which works on both DB and app-tier nodes) the
    # same as an explicit pin, so this fallback only ever fires on a genuinely
    # fresh install. A customer who wants to guarantee their running patch
    # version never changes automatically should also enable lock_db_version
    # (writes /db/.lock_version_file with the exact running version), which
    # makes their pin explicit_pin: true regardless of install state.
    #
    # Version matching uses Gem::Version for component-wise ordering so that
    # "16.10" sorts newer than "16.4" (lexical order gets this wrong).
    # Series membership is determined by matching the leading components of each
    # known version against short_version (e.g. short_version "9.5" matches
    # "9.5.25" but NOT "9.6.24"; short_version "16" matches "16.4", "16.10").
    #
    # Returns the best available version string, or raises if none can be resolved.
    def resolve_pg_package_version(known_versions, install_version, short_version, explicit_pin: false)
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
              "(explicitly pinned via lock_version_file or EY_POSTGRES_VERSION). " \
              "Known versions for series #{short_version}: #{known_versions}. " \
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
              "Known versions: #{known_versions}. Contact support."
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
        "This also applies to already-provisioned instances during reconverge — to pin the " \
        "exact running version and prevent automatic patch changes, enable lock_db_version " \
        "in the environment settings. To suppress this warning, update attributes/version.rb."
      )
      best
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
