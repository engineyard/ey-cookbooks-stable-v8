resin_path = "/usr/local/ey_resin/ruby/bin"
gem_bin_path = "/opt/chef/embedded/bin"
bin_path = "/usr/local/bin"

# 2.1.0 adds the PostgreSQL 15+ (pg_backup_start/pg_backup_stop) and MySQL 8.4
# (SHOW BINARY LOG STATUS) statements. 2.0.4 predates both removals, so on v8
# (PG16 / MySQL 8.4) the master could not be snaplocked and db_replica creation
# failed.
snaplock_version = "2.1.0"
execute "install ey-snaplock" do
  command "wget https://ey-primer-gems.s3.amazonaws.com/ey_snaplock-#{snaplock_version}.gem && #{gem_bin_path}/gem install /tmp/ey_snaplock-#{snaplock_version}.gem"
  cwd "/tmp"
  not_if "#{gem_bin_path}/gem list ey_snaplock | grep #{snaplock_version}"
end

chef_gem "ey_cloud_server" do
  version "1.5.0"
  compile_time false
end

chef_gem "ey_services_setup" do
  version "0.0.8"
  compile_time false
end

chef_gem "ey_stonith" do
  version "0.4.3.pre1"
  compile_time false
end

["eybackup", "eyrestore", "ey-snapshots", "ey-snaplock"].each do |executable|
  link "#{bin_path}/#{executable}" do
    to "#{gem_bin_path}/#{executable}"
    only_if { ::File.exist?("#{gem_bin_path}/#{executable}") }
  end
end

# executable needed for deploys
directory resin_path do
  owner "root"
  group "root"
  mode "0755"
  recursive true
  action :create
end

["ruby", "gem", "engineyard-serverside", "ey-services-setup"].each do |executable|
  link "#{resin_path}/#{executable}" do
    to "#{gem_bin_path}/#{executable}"
  end
end
