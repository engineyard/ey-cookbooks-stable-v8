#
# Cookbook:: dr_failover
# Recipe:: postgresql_failover
#

# PostgreSQL 16 removed the promote_trigger_file GUC, so touching a trigger file
# no longer promotes anything -- the standby would silently stay in recovery.
# Promote via pg_promote() instead (same approach as eydr::postgres_replication).
execute "promote-slave-to-master" do
  command %(psql -U postgres -c "SELECT pg_promote();")
end
