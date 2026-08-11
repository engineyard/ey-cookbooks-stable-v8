# MySQL 8.4 removed the SLAVE/MASTER replication vocabulary that 5.7 requires,
# and the two spellings are mutually exclusive -- each one is a syntax error on
# the other server. Verified against real servers:
#
#   statement                      MySQL 8.4.10          MySQL 5.7.44
#   show slave status              ERROR 1064 (syntax)   OK
#   show replica status            OK                    ERROR 1064 (syntax)
#   stop  slave                    ERROR 1064 (syntax)   OK
#   stop  replica                  OK                    ERROR 1064 (syntax)
#   reset slave  [all]             ERROR 1064 (syntax)   OK
#   reset replica [all]            OK                    ERROR 1064 (syntax)
#   CHANGE MASTER TO               ERROR 1064 (syntax)   OK
#   CHANGE REPLICATION SOURCE TO   OK                    ERROR 1064 (syntax)
#
# (CHANGE MASTER TO is *deprecated but accepted* on 8.0 -- verified on 8.0.46 --
# and fully REMOVED in 8.4, verified ERROR 1064 on 8.4.10. Do not describe it as
# merely deprecated for 8.4.)
#
# Why gate rather than switch outright: these cookbooks are the v8 line, and
# AWSM's stack restrictions currently permit only postgres16 / mysql8_4 / no_db
# for the v8 stack label (ey-awsm lib/awsm/stack_restrictions.rb,
# STACK_LABELS_STABLE_V8_RESTRICTIONS denies mysql5_7, mysql8_0, mariadb10_0 and
# the Aurora variants), so in practice a v8 environment is 8.4. The gate is
# therefore defense-in-depth rather than a live 5.7-on-v8 requirement:
#   * these recipes are shared with / backported to the v7 line, where 5.7 and
#     8.0 ARE live, so the legacy branch must keep emitting the legacy spelling;
#   * node["mysql"]["short_version"] can still be forced to 5.7/8.0 via the
#     EY_MYSQL_VERSION override or a /db/.lock_db_version lock file
#     (see ey-mysql/attributes/version.rb), independently of the stack label;
#   * if the restriction list is ever relaxed, an un-gated statement becomes a
#     silent breakage rather than a caught one.
# Either way the rule holds: never switch a replication statement outright --
# select it by major version.
#
# The SHOW ... STATUS *output field names* were renamed alongside the statement
# (Slave_IO_Running -> Replica_IO_Running, Seconds_Behind_Master ->
# Seconds_Behind_Source, Relay_Master_Log_File -> Relay_Source_Log_File), so
# anything parsing that output must be gated too, not just the statement.
#
# See Oracle's 8.4 added/deprecated/removed list:
# https://docs.oracle.com/cd/E17952_01/mysql-8.4-en/added-deprecated-removed.html
module EY
  module MySQLReplicationSyntax
    # Majors that use the REPLICA/SOURCE vocabulary. 8.0 accepts both spellings
    # (REPLICA added in 8.0.22, SLAVE deprecated in 8.0.26 but still accepted);
    # it is listed here so 8.0 and 8.4 behave identically, matching the existing
    # `%w[8.0 8.4].include?(...)` gates in ey-mysql/resources/mysql_slave.rb.
    MODERN_MAJORS = %w[8.0 8.4].freeze

    def self.modern?(short_version)
      MODERN_MAJORS.include?(short_version.to_s)
    end

    # SQL statements.
    def self.show_replica_status(short_version)
      modern?(short_version) ? "show replica status" : "show slave status"
    end

    def self.stop_replica(short_version)
      modern?(short_version) ? "stop replica" : "stop slave"
    end

    def self.reset_replica(short_version, all: false)
      base = modern?(short_version) ? "reset replica" : "reset slave"
      all ? "#{base} all" : base
    end

    # SHOW ... STATUS output field names.
    def self.io_running_field(short_version)
      modern?(short_version) ? "Replica_IO_Running" : "Slave_IO_Running"
    end

    def self.sql_running_field(short_version)
      modern?(short_version) ? "Replica_SQL_Running" : "Slave_SQL_Running"
    end

    def self.seconds_behind_field(short_version)
      modern?(short_version) ? "Seconds_Behind_Source" : "Seconds_Behind_Master"
    end

    def self.relay_log_file_field(short_version)
      modern?(short_version) ? "Relay_Source_Log_File" : "Relay_Master_Log_File"
    end
  end
end

class Chef
  class Recipe
    # Convenience wrappers so recipes/resources can ask without repeating the
    # node lookup. Kept thin: all the version logic lives in the module above.
    def mysql_replication_modern?
      ::EY::MySQLReplicationSyntax.modern?(node["mysql"]["short_version"])
    end

    def mysql_show_replica_status_statement
      ::EY::MySQLReplicationSyntax.show_replica_status(node["mysql"]["short_version"])
    end
  end
end
