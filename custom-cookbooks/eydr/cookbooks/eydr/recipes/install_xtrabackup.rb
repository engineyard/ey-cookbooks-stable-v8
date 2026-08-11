#
# Cookbook:: dr_replication
# Recipe:: install_xtrabackup
#
# On Noble, XtraBackup is installed from the Percona apt repo rather than a
# hardcoded focal tarball. The XtraBackup major MUST match the MySQL server
# major (XtraBackup 8.0 cannot back up an 8.4 server and vice versa), so the
# repo + package are selected by the environment's MySQL short_version:
#   * mysql8_0 -> pxb-80        / percona-xtrabackup-80  (migration-window DR replica)
#   * mysql8_4 -> pxb-84-lts    / percona-xtrabackup-84
# `innobackupex` was removed in XtraBackup 8.x; the 8.x tools provide
# `xtrabackup`/`xbstream`. The repo is added with apt_repository (matching the
# ey-mysql cookbook's Percona-repo pattern) — `percona-release` is not in
# Ubuntu's archives and cannot be installed as a plain package.

short_version = node["mysql"]["short_version"]

pxb = case short_version
      when "8.0"
        { repo: "pxb-80",     package: "percona-xtrabackup-80" }
      when "8.4"
        { repo: "pxb-84-lts", package: "percona-xtrabackup-84" }
      else
        raise "eydr::install_xtrabackup: unsupported MySQL short_version " \
              "#{short_version.inspect} (expected 8.0 or 8.4)"
      end

# Add the Percona XtraBackup tools repo for the matching major.
apt_repository "percona-#{pxb[:repo]}" do
  uri "http://repo.percona.com/#{pxb[:repo]}/apt"
  distribution `lsb_release -cs`.strip
  components ["main"]
  keyserver "keyserver.ubuntu.com"
  key "9334A25F8507EFA5"
end.run_action(:add)

# Install the XtraBackup major that matches the MySQL server major.
package pxb[:package] do
  action :install
end

# libaio is required by xtrabackup; on Noble it is provided by libaio1t64.
package "libaio1t64" do
  action :install
end

# qpress (used for compressed backup streams) ships from the same Percona repo.
package "qpress" do
  action :install
end
