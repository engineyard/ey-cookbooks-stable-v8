ey_cloud_report "mysql monitoring" do
  message "processing mysql monitoring started"
end

template "/engineyard/bin/check_mysql.sh" do
  source "check_mysql.sh.erb"
  backup 0
  owner "mysql"
  group "mysql"
  mode "751"
  variables({
    dbpass: node.engineyard.environment["db_admin_password"],
    # MySQL 8.4 removed `show slave status` and renamed its output fields, so the
    # replication check must use the spelling that matches this server's major
    # version. See ey-mysql/libraries/replication_syntax.rb
    show_replica_status: ::EY::MySQLReplicationSyntax.show_replica_status(node["mysql"]["short_version"]),
    io_running_field: ::EY::MySQLReplicationSyntax.io_running_field(node["mysql"]["short_version"]),
    sql_running_field: ::EY::MySQLReplicationSyntax.sql_running_field(node["mysql"]["short_version"]),
    seconds_behind_field: ::EY::MySQLReplicationSyntax.seconds_behind_field(node["mysql"]["short_version"]),
  })
end

ey_cloud_report "mysql monitoring" do
  message "processing mysql monitoring finished"
end
