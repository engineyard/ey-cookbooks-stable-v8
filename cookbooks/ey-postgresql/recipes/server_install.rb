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
known_versions = []
`apt-cache madison postgresql-server-dev-#{postgres_version} |awk '{print $3'}`.split(/\n+/).each { |v| known_versions.append(v.split("-")[0]) }
# madison lists one row per suite/component the same version is published in, so
# a single available patch appears many times. Dedupe: the duplicates carry no
# information and make the version list in any error message read as corrupted.
known_versions.uniq!
# Compile-phase resolution, used only as the template's default value -- the
# "check lock version" ruby_block below re-resolves at converge time and
# overwrites it. Both calls go through resolve_pg_version_pin so they apply the
# same precedence (lock file, then EY_POSTGRES_VERSION, then the version already
# installed on this node, then the unpinned default attribute).
#
# This one must never raise, because it runs before the resources below have
# had their chance to run. A stale lock version file left behind after
# lock_db_version was switched off is the case that matters: the
# "remove lock version file" execute exists to delete exactly that file, but
# it is a converge-time resource, so raising here would abort the run before
# the cleanup that would have fixed it. Fall back to the raw attribute and let
# the converge-time block -- which runs after the cleanup, and whose value is
# the one the install script actually uses -- raise if the pin is still
# genuinely unresolvable by then.
package_version = begin
  install_version, pin, pin_source = resolve_pg_version_pin(node, postgres_version)
  resolve_pg_package_version(known_versions, install_version, postgres_version,
                             pin: pin, pin_source: pin_source)
rescue RuntimeError => e
  Chef::Log.info("ey-postgresql: deferring version resolution to converge time (#{e.message})")
  node["postgresql"]["latest_version"]
end

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
    # Resolve again at converge time. The lock version file may have been
    # created earlier in this same run (see the "dropping lock version file"
    # execute above), and on instances booted from a snapshot it is not
    # present during the compile phase at all -- so the compile-phase result
    # can be stale by the time the install script actually runs.
    #
    # resolve_pg_version_pin decides both the version and whether it is a pin
    # that must match exactly. The case that matters here is a node where
    # PostgreSQL is already installed: it pins to the version dpkg reports,
    # so an already-provisioned instance can never have its running database's
    # patch version swapped as a side effect of an unrelated converge -- and,
    # because the pin is the installed version rather than a fixed attribute,
    # the exact match always succeeds and the converge proceeds. Only a
    # genuinely fresh instance falls back to newest-in-series, which is the
    # case that would otherwise fail to provision at all once the attribute's
    # patch version ages out of the distro's apt window.
    install_version, pin, pin_source = resolve_pg_version_pin(node, postgres_version)
    package_version = resolve_pg_package_version(known_versions, install_version, postgres_version,
                                                 pin: pin, pin_source: pin_source)
    # resolve_pg_package_version logs which version this converge resolved to and
    # why -- info on the exact-match path, warn when it had to move -- so every
    # outcome is on the record in the converge log.
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
