include_recipe "ey-db-ssl::setup"

cookbook_file "/engineyard/bin/mysql_start" do
  source "mysql_start"
  mode "744"
end

ey_cloud_report "report starting mysql" do
  message "starting mysql"
  not_if "/etc/init.d/mysql status"
end

execute "start-mysql" do
  sleeptime = 15      # check mysql's status every 15 seconds
  sleeplimit = 7200   # give mysql 2 hours to start (for long recovery operations)

  command "/engineyard/bin/mysql_start --password #{node.engineyard.environment['db_admin_password']} --check #{sleeptime} --timeout #{sleeplimit}"

  timeout sleeplimit

  not_if "/etc/init.d/mysql status"
end

service "mysql" do
  provider Chef::Provider::Service::Systemd
  action :enable
end

# The Percona packages auto-start mysqld on the packaged default datadir
# (/var/lib/mysql) with auto-generated self-signed SSL certs *before* the EY
# config (EY datadir + EY SSL certs in percona-server.cnf) is activated via the
# my.cnf alternatives symlink. The start-mysql step above is `not_if` mysqld is
# already running, so on a fresh converge it is skipped and nothing ever makes
# mysqld re-read the EY config. Without this explicit restart mysqld keeps
# serving from /var/lib/mysql with an auto-generated cert, so clients that
# (per ey-db-ssl / user_my.cnf) VERIFY_CA against the EY root CA fail with
# "certificate verify failed", and data lands on the wrong volume.
#
# This restart was hardcoded to 8.0 only, so 8.4 environments never got the
# config reload. Fire it for every supported 8.x line, and guard on the
# version's own datadir (was hardcoded to 8.0) so it stays idempotent: it runs
# only on the first converge (empty EY datadir) and is skipped once mysqld is
# serving from there.
if node["mysql"]["short_version"].to_s.start_with?("8.")
  service "mysql" do
    provider Chef::Provider::Service::Systemd
    action :restart
    not_if { ::File.exist?(::File.join(node["mysql"]["datadir"], "mysql.ibd")) }
  end
end

# The restart above only fires on a genuinely fresh converge (empty EY
# datadir), so it never reaches an ALREADY-provisioned 8.4 instance. On 8.4,
# my.conf.erb writes `mysql_native_password=ON` into
# percona-server.cnf so root@localhost's ALTER USER ... IDENTIFIED WITH
# mysql_native_password (ey-mysql::master) has a loaded plugin to attach to.
# Re-applying this cookbook fix to an existing, already-running 8.4 master
# re-renders the config file but does not by itself make the already-running
# mysqld reload it, so the plugin stays unloaded and the ALTER keeps failing
# with ERROR 1524. Restart once (tracked with a marker file in the EY
# datadir) so existing environments pick up the config change on their next
# converge, not only brand-new ones. On a genuinely fresh converge this fires
# once redundantly alongside the restart above (harmless: no clients are
# connected yet during initial provisioning) and is then a no-op forever
# after via the marker.
if node["mysql"]["short_version"].to_s == "8.4"
  native_password_marker = ::File.join(node["mysql"]["datadir"], ".native_password_reload")

  service "mysql" do
    provider Chef::Provider::Service::Systemd
    action :restart
    not_if { ::File.exist?(native_password_marker) }
  end

  file native_password_marker do
    owner "mysql"
    group "mysql"
    content ""
    action :create_if_missing
  end
end
