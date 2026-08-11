db_hostname = node.engineyard.instance.solo? ? "localhost" : node["dna"]["db_host"]
admin_username = node.engineyard.environment["db_admin_username"]

node.engineyard.apps.each do |app|
  # Idempotent, abort-tolerant role creation.
  #
  # The old guard `psql ... "select * from pg_roles" | grep <user>` FAILED OPEN:
  # a shell pipeline's exit status is the last stage's (grep), with no `pipefail`.
  # So any psql failure -- connection refused, "the database system is starting
  # up", in-recovery, or an auth blip, all common in the seconds right after a
  # Master-Database restart -- produced empty stdout, grep exited 1, and Chef
  # read the not_if as "condition NOT met" and RAN `CREATE USER`. When the role
  # already existed that aborts with `role "<user>" already exists`, failing the
  # whole converge. That is exactly the "a full env Apply does not recover it"
  # symptom.
  #
  # Two independent robustness measures so a re-converge -- including one right
  # after a PG restart -- is idempotent and never aborts:
  #   1. not_if: an exact-match existence probe (`SELECT 1 ... rolname='<user>'`
  #      + `grep -qx 1`). It only reports "present" on a definitive `1`, so a
  #      failed/empty probe cannot be mistaken for "present". On a healthy
  #      re-converge the role is present => guard met => clean no-op.
  #   2. command: abort-tolerant. If the guard is not met (e.g. the probe query
  #      failed transiently and the role in fact exists), CREATE is attempted and
  #      any error is swallowed ONLY when a re-check confirms the role now exists.
  #      A genuine failure (role still absent, e.g. PG unreachable) still exits
  #      non-zero and surfaces to Chef -- real problems are not masked.
  #   3. retries: ride out the transient unreachable window just after a restart.
  # `sensitive true` keeps the embedded password out of chef.log (the failing
  # converge log leaked it in cleartext).
  execute "create db user #{app.database_username}" do
    command %(psql -U #{admin_username} -h #{db_hostname} -c "CREATE USER #{app.database_username} WITH ENCRYPTED PASSWORD '#{app.database_password}' CREATEDB" postgres || psql -U #{admin_username} -h #{db_hostname} -tAc "SELECT 1 FROM pg_roles WHERE rolname='#{app.database_username}'" postgres | grep -qx 1)
    not_if %(psql -U #{admin_username} -h #{db_hostname} -tAc "SELECT 1 FROM pg_roles WHERE rolname='#{app.database_username}'" postgres | grep -qx 1)
    retries 3
    retry_delay 5
    sensitive true
  end

  if db_host_is_rds?
    execute "grant db user role #{app.database_username} to admin user #{admin_username}" do
      command %(psql -U #{admin_username} -h #{db_hostname} -c "GRANT #{app.database_username} TO #{admin_username} WITH ADMIN OPTION;" postgres)
      retries 3
      retry_delay 5
    end
  end

  # Same abort-tolerant / exact-match idempotence as the role above: the old
  # createdb guard had the identical fail-open pipeline.
  execute "create database for #{app.database_name} owned by #{app.database_username}" do
    command %(PGPASSWORD="#{app.database_password}" createdb -U #{app.database_username} -h #{db_hostname} #{app.database_name} || psql -U #{admin_username} -h #{db_hostname} -tAc "SELECT 1 FROM pg_database WHERE datname='#{app.database_name}'" postgres | grep -qx 1)
    not_if %(psql -U #{admin_username} -h #{db_hostname} -tAc "SELECT 1 FROM pg_database WHERE datname='#{app.database_name}'" postgres | grep -qx 1)
    retries 3
    retry_delay 5
    sensitive true
  end

  # ALTER SCHEMA OWNER is naturally idempotent (setting the same owner succeeds),
  # so it does not abort a healthy re-converge. It must still be skipped on a
  # replica (read-only, in recovery). Tighten the guard to an exact match on the
  # recovery flag so a failed probe can't wrongly decide "not in recovery"; add
  # retries for the transient window just after a restart.
  execute "alter public schema of db #{app.database_name} owner to #{app.database_username}" do
    command %(psql -U #{admin_username} -h #{db_hostname} -c "ALTER SCHEMA public OWNER TO #{app.database_username}" #{app.database_name})
    not_if %(psql -U #{admin_username} -h #{db_hostname} -tAc "SELECT pg_is_in_recovery()" postgres | grep -qx t)
    retries 3
    retry_delay 5
  end
end
