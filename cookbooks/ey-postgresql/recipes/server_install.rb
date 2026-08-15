# Only add PostgreSQL repository when actually using PostgreSQL stack
if node["dna"]["engineyard"]["environment"]["db_stack_name"] =~ /^postgres|^aurora-postgresql/
  apt_repository "posgresql" do
    uri "https://apt-archive.postgresql.org/pub/repos/apt"
    distribution "#{`lsb_release -cs`.strip}-pgdg-archive"
    components ["main"]
    key "https://www.postgresql.org/media/keys/ACCC4CF8.asc"
  end.run_action(:add)
end

apt_update

postgres_version = node["postgresql"]["short_version"]
install_version = node["postgresql"]["latest_version"]
known_versions = []
`apt-cache madison postgresql-server-dev-#{postgres_version} |awk '{print $3'}`.split(/\n+/).each { |v| known_versions.append(v.split("-")[0]) }
# EY_POSTGRES_VERSION is an explicit customer pin (attributes/version.rb folds it
# into node["postgresql"]["latest_version"] before this recipe runs, so we detect
# it directly from the env var rather than from latest_version itself). Any other
# case is the default per-stack attribute pin, which falls back to the newest
# patch in the series instead of raising. The lock_version_file pin (also
# explicit) is only known at converge time -- see the "check lock version" block.
explicit_env_pin = !fetch_env_var(node, "EY_POSTGRES_VERSION").nil?
package_version = resolve_pg_package_version(known_versions, install_version, postgres_version, explicit_pin: explicit_env_pin)

execute "dropping lock version file" do
  command "echo #{running_pg_version} > #{node['lock_version_file']}"
  action :run
  only_if { lock_db_version && !File.exist?(node["lock_version_file"]) && pg_running }
end

execute "remove lock version file" do
  command "rm #{node['lock_version_file']}"
  only_if { !lock_db_version && File.exist?(node["lock_version_file"]) }
end

ey_cloud_report "postgresql" do
  message "Handling PostgreSQL Install"
end

directory "/etc/postgresql-common" do
  action :create
end

cookbook_file "/etc/postgresql-common/createcluster.conf" do
  source "createcluster.conf"
end

directory "/tmp/src/postgresql" do
  action :create
  recursive true
end

# This ruby block handles if the lock version file is set
# It needs to be done like this since the file isn't present during the compile
# phase on first runs on new instances booted from snapshots
# If a lock version file exists, use the version to set the variables
# on template "/tmp/src/postgresql/install.sh"
ruby_block "check lock version" do
  block do
    lock_version_present = File.exist?(node["lock_version_file"])
    install_version = if lock_version_present
                        `cat #{node["lock_version_file"]}`.strip
                      else
                        node["postgresql"]["latest_version"]
                      end
    # lock_version_file and EY_POSTGRES_VERSION are both explicit, deliberate
    # customer pins -- require an exact match and raise if it's gone rather
    # than silently drifting it. Otherwise this is the default per-stack
    # attribute pin, which falls back to the newest patch in the series.
    # See libraries/helpers.rb#resolve_pg_package_version.
    #
    # This recipe runs on every Chef converge for db/app roles, not only on
    # first boot, so the fallback path could otherwise fire on a routine
    # reconverge of an already-running instance whose default attribute pin
    # has aged out of the apt archive -- silently swapping its installed
    # PostgreSQL patch (and restarting the service) as a side effect of an
    # unrelated Apply. That's worse than the old fail-closed behavior for a
    # live database, so treat "PostgreSQL is already running" the same as an
    # explicit pin: exact-match-or-raise, never an automatic version change.
    # Fallback-to-newest is reserved for what AC3 actually targets -- a
    # genuinely fresh instance (no PostgreSQL running yet) that would
    # otherwise fail to provision at all because the hardcoded attribute pin
    # has moved out of the distro's apt window.
    explicit_pin = lock_version_present || !fetch_env_var(node, "EY_POSTGRES_VERSION").nil? || pg_running
    package_version = resolve_pg_package_version(known_versions, install_version, postgres_version, explicit_pin: explicit_pin)
    run_context.resource_collection.find(template: "/tmp/src/postgresql/install.sh").variables package_version: package_version, postgres_version: postgres_version
  end
end

template "/tmp/src/postgresql/install.sh" do
  source "install.sh.erb"
  owner "root"
  group "root"
  mode "0755"
  variables package_version: package_version, postgres_version: postgres_version
end

# Install postgresql packages using a script
execute "run postgresql install.sh" do
  command "/tmp/src/postgresql/install.sh"
end

template "/etc/profile.d/postgresql.sh" do
  source "postgresql.sh.erb"
  variables version: postgres_version
end
