ey_cloud_report "mysql" do
  message "processing mysql"
end

include_recipe "ey-db-ssl::setup"
include_recipe "ey-mysql::install"
include_recipe "ey-mysql::user_my.cnf"

directory "/db/mysql" do
  owner "mysql"
  group "mysql"
  mode "755"
  recursive true
end

directory node["mysql"]["logbase"] do
  owner "mysql"
  group "mysql"
  mode "755"
  recursive true
end

include_recipe "ey-mysql::startup"

execute "set-root-mysqls-passs" do
  # On a fresh install root@localhost starts as `auth_socket` (OS-peer auth,
  # no password checked), so the FIRST run of this ALTER succeeds as OS root
  # over the socket regardless of any password supplied. That ALTER flips
  # root@localhost to mysql_native_password, so every subsequent re-converge
  # of this exact command needs a REAL credential to authenticate. Relying on
  # `mysql`'s implicit ~/.my.cnf lookup (bare `mysql -u root`) only works when
  # the shell's HOME resolves to /root; under Chef's execute resource this
  # does not hold, so the second and later runs silently connect with NO
  # password and get ERROR 1045 (Access denied ... using password: NO) even
  # though ey-mysql::user_my.cnf (included above) already wrote /root/.my.cnf
  # with this exact password. Point the client at that file explicitly so
  # auth is not environment-dependent.
  command %(mysql --defaults-extra-file=/root/.my.cnf -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '#{node.engineyard.environment['db_admin_password']}'")
end

include_recipe "ey-mysql::setup_app_users_dbs"

include_recipe "ey-backup::mysql"
