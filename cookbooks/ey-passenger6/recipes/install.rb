#
# Cookbook:: ey-passenger6
# Recipe:: install
#

recipe = self

# Notify dashboard
ey_cloud_report "passenger6" do
  message "Installing Passenger 6 started"
end

# Install gems required by Passenger standalone.
# NOTE: unlike ey-passenger5, we do NOT pin rack here. Passenger 6.1.x depends on
# rack >= 1.6.13 plus a separate `rackup` gem; the legacy `rack:1.6.4` pin both
# fails that requirement and collides with Passenger 6's `rackup` gem on the
# `rackup` executable ("rackup from rackup conflicts with installed executable
# from rack"). Letting the passenger gem resolve its own rack/rackup installs
# cleanly (passenger 6.1.8 pulls rack 3.2.6 + rackup 2.3.1) and compiles the
# native extension on Noble (Ruby 3.1-3.4).
ruby_block "gems to install" do
  block do
    system("gem install daemon_controller")
  end
end

gem_package "passenger" do
  version node["passenger6"]["version"]
  action :install
end

# Grab version, ssh user, rails_env and port
version       = node["passenger6"]["version"]
ssh_username  = node["owner_name"]
framework_env = node["dna"]["environment"]["framework_env"]

# Write out the advanced configuration file
# From the Passenger Standalone documentation:
# Please note that changes to this file only last until you reinstall or upgrade Phusion Passenger.
# We are currently working on a mechanism for permanently editing the configuration file.
# template "/opt/passenger-server-5.0.29/resources/templates/standalone/config.erb" do
#   owner ssh_username
#   group ssh_username
#   mode 0644
#   source "config.erb"
#   action :create
# end
base_port = node["passenger6"]["port"].to_i
stepping = 200
app_base_port = base_port
# For GEM_PATH and others, the major version is needed. I.e: '3.0.0' instead of '3.0.2'
ruby_major_version = node["ruby"]["version"].sub(/(\d\.\d).\d*/, '\1.0')

node.engineyard.apps.each_with_index do |app, index|
  app_path      = "/data/#{app.name}"
  app_base_port = base_port + (stepping * index)
  log_file      = "#{app_path}/shared/log/passenger.#{app_base_port}.log"
  # Render app control script, this script calls the passenger enterprise binaries using the full path
  template "/engineyard/bin/app_#{app.name}" do
    source  "app_control.erb"
    owner   ssh_username
    group   ssh_username
    mode    "0755"
    backup  0
    variables(
      user: ssh_username,
      app_name: app.name,
      version: version,
      port: app_base_port,
      worker_count: recipe.get_pool_size,
      rails_env: framework_env,
      ruby_version: ruby_major_version
    )
  end

  # Setup log rotate for passenger.log
  logrotate "passenger6_#{app.name}" do
    files log_file
    copy_then_truncate
  end

  # Render monitrc file to watch standalone passenger
  template "/etc/monit.d/passenger6_#{app.name}.monitrc" do
    source "passenger6.monitrc.erb"
    owner "root"
    group "root"
    mode "0666"
    backup 0
    variables(
      app: app.name,
      app_memory_limit: app_server_get_worker_memory_size(app),
      username: ssh_username,
      port: app_base_port,
      version: version
    )
    notifies :run, "execute[reload-monit]", :delayed
  end
end

# Render passenger_monitor script
cookbook_file "/engineyard/bin/passenger_monitor" do
  source "passenger_monitor"
  owner node["owner_name"]
  group node["owner_name"]
  mode "0655"
  backup 0
end

ey_cloud_report "passenger6" do
  message "Installing Passenger 6 finished"
end
