if fetch_env_var(node, "EY_REDIS_ENABLED") =~ /^TRUE$/i
  include_recipe "ey-redis"
end

if fetch_env_var(node, "EY_MEMCACHED_ENABLED") =~ /^TRUE$/i
  include_recipe "ey-memcached"
end

if fetch_env_var(node, "EY_SIDEKIQ_ENABLED") =~ /^TRUE$/i
  include_recipe "ey-sidekiq"
end

if fetch_env_var(node, "EY_LETSENCRYPT_ENABLED") =~ /^TRUE$/i
  include_recipe "ey-letsencrypt"
end

if fetch_env_var(node, "EY_FAIL2BAN_ENABLED") =~ /^TRUE$/i
  include_recipe "ey-fail2ban"
end

# ey-logentries is not available on Stack v8 (Noble). The vendor apt repo
# (rep.logentries.com) is decommissioned — the host is NXDOMAIN — and the
# product line (Logentries -> Rapid7 InsightOps) is EOL / no longer sold, so
# there is no Noble-compatible package source; the recipe also depended on the
# Python-2-only `python-setproctitle`, absent on Noble. Skipped on v8 so an
# opted-in customer gets a clean converge instead of a failed one. (Left in the
# tree for v6/v7 history.)
unless fetch_env_var(node, "EY_LOGENTRIES_API_KEY").nil?
  if node["platform_version"].to_s.start_with?("24.04")
    Chef::Log.warn("ey-logentries is not supported on Ubuntu 24.04 (Noble); the logentries apt repo is decommissioned. Skipping.")
  else
    include_recipe "ey-logentries"
  end
end

if fetch_env_var(node, "EY_CLAMAV_ENABLED") =~ /^TRUE$/i
  include_recipe "ey-clamav"
end