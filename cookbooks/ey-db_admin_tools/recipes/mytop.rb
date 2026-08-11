# mytop (a top-like MySQL monitor) is not in the Ubuntu 24.04 (Noble) archive —
# it was dropped and has no candidate even with universe enabled. It is a DBA
# convenience tool, not part of serving traffic, so a hard failure here must not
# abort the whole DB converge. Install it where available (focal/v6-v7) and skip
# with a warning on Noble; the .mytop config templates below are still written
# (harmless, and correct if mytop is later installed manually, e.g. via CPAN).
if node["platform_version"].to_s.start_with?("24.04")
  Chef::Log.warn("mytop is not available in the Ubuntu 24.04 archive; skipping its package install (config files still written).")
else
  package "mytop" do
    action :install
  end
end

template "/root/.mytop" do
  owner "root"
  mode "0600"
  variables({
    username: node.engineyard.environment["db_admin_username"],
    password: node.engineyard.environment["db_admin_password"],
    database: "mysql",
    host: node["dna"]["instance_role"][/^(db|solo)/] ? "localhost" : node["dna"]["db_host"],
  })
  source "mytop.erb"
end

template "/home/#{node['owner_name']}/.mytop" do
  owner node["owner_name"]
  mode "0600"
  variables({
    username: node.engineyard.apps.first.database_username,
    password: node.engineyard.apps.first.database_password,
    database: node.engineyard.apps.map(&:database_name).first,
    host: node["dna"]["instance_role"][/^(db|solo)/] ? "localhost" : node["dna"]["db_host"],
  })
  source "mytop.erb"
end

