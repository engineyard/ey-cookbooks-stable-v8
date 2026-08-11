provides :mysql_slave
unified_mode true

default_action :action_mysql_slave

property :password, String

require "tempfile"
require "open-uri"

action :action_mysql_slave do
  master_host = new_resource.name
  password = new_resource.password

  execute "start-of-mysql-slave" do
    # Used to add only_ifs to these resources
    command "echo"
  end

  # Is this host already configured as a replica?
  #
  # Two defects fixed here:
  #
  # 1. `show slave status` was removed in MySQL 8.4, so on a v8 8.4 replica it
  #    fails with ERROR 1064 -- the error goes to stderr and stdout is EMPTY, so
  #    the old `!foo.empty?` returned false for every 8.4 host, replica or not.
  #    The `rescue` never helped: a non-zero exit from a backtick does not raise.
  #    Select the statement by major version (5.7 needs SLAVE, 8.x needs
  #    REPLICA -- each is a syntax error on the other).
  #
  # 2. Key off the EXIT STATUS rather than "did anything land on stdout", and
  #    require an actual status row. A future removed statement then surfaces as
  #    a failed command instead of silently reading as "not a replica".
  #
  # Getting this wrong is not cosmetic: this predicate gates
  # `ruby_block "clean up half-done install"` below, whose only_if is
  # `::File.exist?("/db") && !mysql_slave_is_slavey?`. A false negative reduces
  # that to "/db exists" -- i.e. mysql stop + umount /db + rmdir /db against a
  # perfectly healthy replica.
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

  ruby_block "clean up half-done install" do
    block do
      system("/etc/init.d/mysql stop")
      system("umount /db")
      FileUtils.rmdir "/db"
    end
    action :run
    only_if { ::File.exist?("/db") && !mysql_slave_is_slavey? }
  end

  directory "/db" do
    owner "mysql"
    group "mysql"
    mode "755"
    recursive true
  end

  ruby_block "wait-for-db-slave-volume" do
    block do
      sleep 5 until node["db_volume"].found?
    end
  end

  mount "/db" do
    fstype node["db_filesystem"]
    device node["db_volume"].device
    action [:mount, :enable]
    # override the not_if put on all these resources in the slave.rb recipe
    not_if "false"
  end

  ruby_block "wait-for-db-slave-mount" do
    block do
      until system("ls -l /db/mysql")
        sleep 3
        Array(resources(mount: "/db")).each do |resource|
          resource.run_action(:mount)
        end
      end
    end
  end

  bash "grow-db-ebs" do
    code "resize2fs #{node['db_volume'].device}"
    only_if { node["db_volume"].found? }
  end

  handle_mysql_d

  volume_from_slave_snapshot = false
  ruby_block "volume-from-slave-or-not" do
    block do
      volume_from_slave_snapshot = master_host == `[[ -f #{node["mysql"]["datadir"]}/master.info ]] && grep ec2 #{node["mysql"]["datadir"]}/master.info`.strip
    end
  end

  ruby_block "read-master-status" do
    block do
      unless volume_from_slave_snapshot
        file_contents = ::File.read("/db/mysql/.snapshot_backup_master_status.txt")
        node.override["master_log_file"] = file_contents.match(/File:(.*)\n/)[1].strip
        node.override["master_log_pos"] = file_contents.match(/Position:(.*)\n/)[1].strip
        Chef::Log.info("using master_log_file: " + node["master_log_file"].inspect)
        Chef::Log.info("using master_log_pos: " + node["master_log_pos"].inspect)
      end
    end
  end

  file "#{node['mysql']['datadir']}/master.info" do
    action :delete
    only_if { ::File.exist?("#{node['mysql']['datadir']}/master.info") && !volume_from_slave_snapshot }
  end

  file "#{node['mysql']['datadir']}/relay-log.info" do
    action :delete
    only_if { ::File.exist?("#{node['mysql']['datadir']}/relay-log.info") && !volume_from_slave_snapshot }
  end

  execute "remove relay-log.*" do
    cwd node["mysql"]["datadir"]
    command "rm -f #{node['mysql']['datadir']}/relay-log.*"
    only_if { !Dir.glob("#{node['mysql']['datadir']}/relay-log.*").empty? && !volume_from_slave_snapshot }
  end

  execute "remove slave-relay*" do
    cwd node["mysql"]["datadir"]
    command "rm -f #{node['mysql']['datadir']}/slave-relay*"
    only_if { !Dir.glob("#{node['mysql']['datadir']}/slave-relay*").empty? && !volume_from_slave_snapshot && !mysql_slave_is_slavey? }
  end

  # the master writes it's uuid to <datadir>/auto.cnf, the slave needs that removed so it will gen it's own
  file "#{node['mysql']['datadir']}/auto.cnf" do
    action :delete
    Chef::Log.info("removing <datadir>/auto.cnf")
    only_if { node["mysql"]["short_version"] >= "5.6" }
  end

  include_recipe "ey-mysql::startup"

  # Clear the replication metadata repository inherited from the master snapshot.
  #
  # The file deletions above (master.info, relay-log.info, relay-log.*,
  # slave-relay*) only cover the FILE-based repository used by MySQL 5.x. Since
  # 8.0 the applier/connection metadata lives in the InnoDB tables
  # mysql.slave_relay_log_info / mysql.slave_master_info, and in 8.4 the
  # file-based option is gone entirely (relay_log_info_repository no longer
  # exists as a system variable). On 8.4 master.info and relay-log.info are never
  # present, so those deletes are no-ops.
  #
  # A db_slave's /db volume is built from a snapshot of the MASTER, so that
  # InnoDB data arrives carrying the master's stale relay-log coordinates. mysqld
  # then reads metadata pointing at a relay log that the cleanup above just
  # deleted (e.g. slave-relay-bin.000002 when only .000001 exists) and refuses to
  # initialise:
  #
  #   Failed to open the relay log './slave-relay-bin.000002' (relay_log_pos N)
  #   Could not find target log file mentioned in applier metadata in the index file
  #   Replica failed to initialize applier metadata structure from the repository
  #
  # leaving Replica_IO_Running/Replica_SQL_Running = No even though Chef
  # converged successfully. RESET REPLICA drops that repository so the
  # CHANGE REPLICATION SOURCE below starts from the snapshot's coordinates.
  #
  # Must run AFTER ey-mysql::startup (it needs a live mysqld, unlike the file
  # deletions) and BEFORE setup-slave-database. Skipped when the volume came from
  # a slave snapshot, matching the surrounding cleanup, since that already
  # carries valid replica state.
  #
  # RESET REPLICA is the 8.0.22+ spelling; RESET SLAVE was removed in 8.4. Gate
  # on short_version the same way setup-slave-database does below, so 5.7 keeps
  # the legacy statement.
  reset_replica_statement =
    if %w[8.0 8.4].include?(node["mysql"]["short_version"])
      "RESET REPLICA"
    else
      "RESET SLAVE"
    end

  # Also skip when replication is ALREADY RUNNING, which is the re-converge case
  # (Chef Apply / Upgrade on an established replica).
  #
  # The `volume_from_slave_snapshot` guard above cannot cover this: it is
  # file-based (it greps master.info), and master.info never exists on 8.4 --
  # that absence is the very premise of this fix. So on every re-converge of a
  # working 8.4 replica the guard reads false, RESET REPLICA runs, and 8.4
  # refuses it outright:
  #
  #   ERROR 3081 (HY000): This operation cannot be performed with running
  #   replication threads; run STOP REPLICA FOR CHANNEL '' first
  #
  # which fails the whole Chef run at this resource. Verified on
  # sunset-staging 2026-08-04 (release stable-v8-qa-1.0.23): the Infra phase
  # aborted here on an otherwise-healthy streaming replica.
  #
  # Skipping is correct rather than merely convenient: this resource exists to
  # clear stale metadata inherited from the MASTER's snapshot before the replica
  # is first pointed at its source. If the applier/IO threads are already
  # running, the metadata is by definition valid and live -- there is nothing
  # stale to clear, and resetting it would destroy a working replica's position.
  #
  # Deliberately NOT solved by prepending STOP REPLICA: that would stop
  # replication on a healthy replica on every converge, and (verified on a real
  # 8.4.10 server) STOP REPLICA + RESET REPLICA against live metadata can leave
  # the server unable to reopen mysql.slave_master_info. Skip, don't stop.
  #
  # The probe uses performance_schema rather than parsing SHOW REPLICA STATUS so
  # it needs no field-name gating, and is written to fail SAFE: any error or
  # unexpected output yields a non-zero count, i.e. "assume running, skip the
  # reset". A skipped reset on a genuinely new replica is recoverable (the
  # pre-existing behaviour); a wrongly-run reset breaks replication.
  # No version gate needed: performance_schema.replication_applier_status and
  # replication_connection_status exist with these column names on 5.7, 8.0 and
  # 8.4 alike (unlike SHOW REPLICA STATUS, whose spelling and output fields
  # changed). Verified on real 5.7.44, 8.0.46 and 8.4.10 servers.
  replication_threads_running_query =
    "SELECT (SELECT COUNT(*) FROM performance_schema.replication_applier_status " \
    "WHERE service_state = 'ON') + (SELECT COUNT(*) FROM " \
    "performance_schema.replication_connection_status WHERE service_state IN " \
    "('ON', 'CONNECTING')) AS running"

  execute "reset-replica-metadata-repository" do
    command %(mysql -e "#{reset_replica_statement}")
    not_if { volume_from_slave_snapshot }
    not_if do
      result = Mixlib::ShellOut.new(
        "mysql", "-N", "-B", "-e", replication_threads_running_query
      ).run_command
      if result.exitstatus.zero?
        running = result.stdout.strip.to_i
        Chef::Log.info(
          "reset-replica-metadata-repository: #{running} replication thread(s) " \
          "running; #{running.zero? ? 'proceeding with' : 'skipping'} " \
          "#{reset_replica_statement}"
        )
        running.positive?
      else
        # Fail safe: could not determine state, so assume a live replica.
        Chef::Log.warn(
          "reset-replica-metadata-repository: could not probe replication state " \
          "(#{result.stderr.strip}); skipping #{reset_replica_statement}"
        )
        true
      end
    end
  end

  template "/tmp/clear_binlogs_from_slave.sh" do
    owner "root"
    group "root"
    mode "0755"
    source "clear_binlogs_from_slave.sh.erb"
    variables({ datadir: node["mysql"]["datadir"] })
  end

  execute "clean-up-master's-bin-logs" do
    action :run
    command "/tmp/clear_binlogs_from_slave.sh"
    only_if %(mysql -e"show global variables like 'log_bin'"|grep 'OFF')
  end

  ruby_block "setup-slave-database" do
    block do
      unless volume_from_slave_snapshot
        # MySQL 8.0.23+/8.4 deprecated CHANGE MASTER TO / START SLAVE (and the
        # MASTER_* keywords) in favour of CHANGE REPLICATION SOURCE TO /
        # START REPLICA with SOURCE_* keywords. Use the modern syntax on 8.x,
        # keep the legacy syntax for older stacks (5.x).
        if %w[8.0 8.4].include?(node["mysql"]["short_version"])
          change_master_command =  "CHANGE REPLICATION SOURCE TO"
          change_master_command << " SOURCE_HOST='#{master_host}',"
          change_master_command << " SOURCE_USER='replication',"
          change_master_command << " SOURCE_PASSWORD='#{password}',"
          change_master_command << " SOURCE_LOG_FILE='#{node['master_log_file']}',"
          change_master_command << " SOURCE_LOG_POS=#{node['master_log_pos']},"
          # Setup SSL
          change_master_command << " SOURCE_SSL=1,"
          change_master_command << " SOURCE_SSL_CA='#{node['mysql']['ssldir']}/root.crt',"
          change_master_command << " SOURCE_SSL_CERT='#{node['mysql']['ssldir']}/server.crt',"
          change_master_command << " SOURCE_SSL_KEY='#{node['mysql']['ssldir']}/server.key'"
          start_replica_command = "start replica"
        else
          change_master_command =  "CHANGE MASTER TO"
          change_master_command << " MASTER_HOST='#{master_host}',"
          change_master_command << " MASTER_USER='replication',"
          change_master_command << " MASTER_PASSWORD='#{password}',"
          change_master_command << " MASTER_LOG_FILE='#{node['master_log_file']}',"
          change_master_command << " MASTER_LOG_POS=#{node['master_log_pos']},"
          # Setup SSL
          change_master_command << " MASTER_SSL=1,"
          change_master_command << " MASTER_SSL_CA='#{node['mysql']['ssldir']}/root.crt',"
          change_master_command << " MASTER_SSL_CERT='#{node['mysql']['ssldir']}/server.crt',"
          change_master_command << " MASTER_SSL_KEY='#{node['mysql']['ssldir']}/server.key'"
          start_replica_command = "start slave"
        end

        # Pass the SQL as a discrete argv element via Mixlib::ShellOut (no shell,
        # no string interpolation into a subshell) so the replication command
        # cannot be re-parsed by a shell. Behaviour matches the previous
        # `mysql -e "<sql>"` invocation.
        Chef::Log.info "executing change master command"
        Mixlib::ShellOut.new("mysql", "-e", change_master_command).run_command

        Chef::Log.info start_replica_command
        Mixlib::ShellOut.new("mysql", "-e", start_replica_command).run_command
      end
    end
  end

  execute "stop-of-mysql-slave" do
    # Used to add only ifs to these resources
    command "echo"
  end
end
