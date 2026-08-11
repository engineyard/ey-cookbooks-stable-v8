include_recipe "ey-prechef"

execute "reload-systemd" do
  command "systemctl daemon-reload"
  action :nothing
end

execute "reload-monit" do
  command "monit reload"
  action :nothing
end

# Make every apt front-end WAIT for the dpkg lock instead of failing instantly.
#
# Ubuntu ships apt-daily.timer / apt-daily-upgrade.timer enabled, and they fire
# shortly after boot -- i.e. right in the middle of the first Chef converge. When
# apt-daily holds /var/lib/dpkg/lock-frontend, Chef's package resources die with
#   E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process N
#   ... returned 100
# and the whole run aborts (observed on a fresh v8 db_slave: apt-daily ran
# 10:54:13-10:54:24 while Chef was installing packages 10:52-10:54).
#
# APT 2.8.3 defaults DPkg::Lock::Timeout to 120 for the `apt` binary ONLY
# (binary::apt::DPkg::Lock::Timeout); `apt-get` -- which is what Chef invokes --
# resolves no timeout at all and therefore fails on first contention. Setting it
# unscoped here applies to apt-get/apt-cache/aptitude as well.
#
# Written before "update-apt-sources" and apt_update so it covers the very first
# apt call of the run.
file "/etc/apt/apt.conf.d/80ey-dpkg-lock-timeout" do
  content "DPkg::Lock::Timeout \"300\";\n"
  owner "root"
  group "root"
  mode "0644"
  action :create
end

# Clean up legacy PGDG repository file that causes apt-get update to fail
# This addresses GHI-14034: existing instances that already have the broken file from earlier runs
# The file will be re-created later by PostgreSQL recipes if actually needed
# Must happen before apt-get update to prevent failures
file "/etc/apt/sources.list.d/posgresql.list" do
  action :delete
  only_if { ::File.exist?("/etc/apt/sources.list.d/posgresql.list") }
end

execute "update-apt-sources" do
  command <<-EOH
    cp /etc/apt/sources.list /etc/apt/sources.list.bak &&
    sed -i 's|http://.*.ec2.archive.ubuntu.com/ubuntu/|http://archive.ubuntu.com/ubuntu/|g' /etc/apt/sources.list &&
    apt-get update
  EOH
  action :run
end

apt_update

package "openssl"

package "run-one" # Makes the run-one binary accessible across system, similar to lockrun in previous stack

include_recipe "ey-sysctl::tune"
include_recipe "ey-core::swap"
include_recipe "ey-instance-api"
include_recipe "ey-syslog-ng"
include_recipe "ey-timezones"
include_recipe "ey-logrotate"
include_recipe "ey-hosts"
include_recipe "ey-core::sshd"
include_recipe "ey-unattended-upgrades"
