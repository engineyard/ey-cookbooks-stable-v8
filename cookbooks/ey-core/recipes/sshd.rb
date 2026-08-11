cookbook_file "/etc/ssh/sshd_config" do
  owner "root"
  group "root"
  backup 0
  mode "0600"
  source "sshd_config"
  not_if { ::File.exist?("/etc/ssh/keep.sshd_config") }
end

bash "Enforce strong Moduli" do
  code "awk '$5 >= 3071' /etc/ssh/moduli > /etc/ssh/moduli.strong && cp /etc/ssh/moduli.strong /etc/ssh/moduli"
  not_if { ::File.exist?("/etc/ssh/moduli.strong") }
end

# On Ubuntu 24.04 (Noble) the OpenSSH server systemd unit is "ssh.service".
# The "sshd.service" alias that existed on Focal (20.04, stack v6/v7) was
# removed on Noble, so `systemctl restart sshd` fails with "Unit sshd.service
# not found" (exit 5). Stack v8 is Noble-only, so restart the "ssh" unit.
service "ssh" do
  action :restart
end