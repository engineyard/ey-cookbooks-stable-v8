#
# Cookbook:: dr_failover
# Recipe:: mysql_failover
#

bash "remove-replication-configuration" do
  code "rm /db/mysql/master.info"
  only_if { ::File.exist?("/db/mysql/master.info") }
end

bash "remove-replication-configuration" do
  code "rm /etc/mysql.d/replication.cnf"
  only_if { ::File.exist?("/etc/mysql.d/replication.cnf") }
end

bash "remote-replication-relay-files" do
  code "rm /db/mysql/*relay*"
  only_if { ::File.exist?("/db/mysql/relay-log.info") }
end

case node["engineyard"]["environment"]["db_stack_name"]
when "mysql5_0", "mysql5_1"
  ruby_block "promote-5.0-5.1-slave-to-master" do
    block do
      `mysql -u root -p#{node["owner_pass"]} -e 'stop slave;'`
      `mysql -u root -p#{node["owner_pass"]} -e 'CHANGE master TO master_host='';'`
      `mysql -u root -p#{node["owner_pass"]} -e 'SET global read_only = 0;'`
      `mysql -u root -p#{node["owner_pass"]} -e 'flush privileges;'`
    end
  end
when "mysql5_5"
  ruby_block "promote-5.5-slave-to-master" do
    block do
      `mysql -u root -p#{node["owner_pass"]} -e 'stop slave;'`
      `mysql -u root -p#{node["owner_pass"]} -e 'reset slave all;'`
      `mysql -u root -p#{node["owner_pass"]} -e 'SET global read_only = 0;'`
      `mysql -u root -p#{node["owner_pass"]} -e 'flush privileges;'`
    end
  end
# Before this arm existed the case had arms for mysql5_0/5_1/5_5 only, so on a v8
# mysql8_4 (or mysql5_7 / mysql8_0) environment NO arm matched: failover skipped
# the promotion entirely, never stopped replication and never cleared read_only,
# then fell through to the unconditional MySQL restart below. The "promoted" host
# came back still read-only and still pointed at a dead source -- a silent
# no-op failover. The PostgreSQL side was fixed separately.
#
# 8.4 removed STOP SLAVE / RESET SLAVE ALL, and 5.7 does not accept the REPLICA
# spelling, so the statements are selected by major version.
#
# super_read_only is cleared explicitly and FIRST, for clarity of intent rather
# than necessity: verified on real 5.7.44 and 8.4.10 servers that setting
# super_read_only=1 forces read_only=1, and that `SET global read_only = 0`
# alone also clears super_read_only. Clearing it explicitly documents that a
# promoted source must accept writes from SUPER users too, and makes the
# transition independent of that implicit coupling.
when "mysql5_7", "mysql8_0", "mysql8_4"
  ruby_block "promote-5.7-8.x-replica-to-source" do
    block do
      modern = %w[mysql8_0 mysql8_4].include?(node["engineyard"]["environment"]["db_stack_name"])
      stop_statement = modern ? "stop replica" : "stop slave"
      reset_statement = modern ? "reset replica all" : "reset slave all"

      statements = [
        stop_statement,
        reset_statement,
        "SET global super_read_only = 0",
        "SET global read_only = 0",
        "flush privileges",
      ]

      statements.each do |statement|
        # Pass credentials and SQL as discrete argv elements (no shell), matching
        # the Mixlib::ShellOut pattern in ey-mysql/resources/mysql_slave.rb, so
        # neither the password nor the statement is re-parsed by a shell.
        result = Mixlib::ShellOut.new(
          "mysql", "-u", "root", "-p#{node['owner_pass']}", "-e", statement
        ).run_command
        if result.exitstatus.zero?
          Chef::Log.info("mysql_failover: #{statement} ok")
        else
          # RESET REPLICA ALL on a host that was never a replica exits non-zero;
          # that is not fatal to a promotion, so log and continue rather than
          # aborting the failover half-done.
          Chef::Log.warn("mysql_failover: #{statement} failed: #{result.stderr.strip}")
        end
      end
    end
  end
else
  # Fail loudly rather than silently skipping the promotion, which is what the
  # missing 5.7/8.x arms did on v8.
  ruby_block "unsupported-db-stack-for-mysql-failover" do
    block do
      raise "eydr::mysql_failover: no promotion path for db_stack_name " \
            "#{node['engineyard']['environment']['db_stack_name'].inspect} -- " \
            "refusing to restart MySQL and report a failover that did not happen"
    end
  end
end

bash "restart-mysql" do
  code "/etc/init.d/mysql restart"
end
