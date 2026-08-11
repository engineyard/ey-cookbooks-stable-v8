include_recipe "ey-db-ssl::setup"
include_recipe "ey-mysql::client"

mysql_slave node["dna"]["db_host"] do
  password node["owner_pass"]
end

# Same predicate as ey-mysql/resources/mysql_slave.rb, redefined at recipe level
# because it is used below to attach not_if guards to the resource collection.
# Version-gated and exit-status-based for the reasons documented there:
# `show slave status` was removed in MySQL 8.4, and on 8.4 it fails with
# ERROR 1064 leaving stdout empty -- so the old `!foo.empty?` form was always
# false on v8, defeating the "already a replica, don't re-run" idempotence guard.
def self.mysql_slave_is_slavey?
  statement = ::EY::MySQLReplicationSyntax.show_replica_status(
    node["mysql"]["short_version"]
  )
  io_field = ::EY::MySQLReplicationSyntax.io_running_field(
    node["mysql"]["short_version"]
  )
  result = Mixlib::ShellOut.new("mysql", "-e", statement).run_command
  return false unless result.exitstatus.zero?

  result.stdout.include?(io_field)
rescue StandardError => e
  Chef::Log.warn("mysql_slave_is_slavey? could not determine replica state: #{e.message}")
  false
end

# Only run the mysql_slave recipes if it isn't already a slave
updating = false

resources_collection = run_context.resource_collection

resources_collection.each do |r|
  updating = true if r.to_s == "execute[start-of-mysql-slave]"
  updating = false if r.to_s == "execute[stop-of-mysql-slave]"

  if updating && (!r.not_if || r.not_if.empty?)
    r.not_if do
      mysql_slave_is_slavey?
    end
  end
end

handle_mysql_d
