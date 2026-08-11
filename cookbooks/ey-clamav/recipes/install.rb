clamav = node["clamav"]

# Install the release's default clamav-daemon rather than pinning an exact
# version. The old pin (node["clamav"]["version"]) was a Focal package version
# (0.103.6+dfsg-0ubuntu0.20.04.1) that does not exist in Noble's repos, so a
# pinned install fails on v8. Letting apt resolve the release default keeps
# this working across Ubuntu releases (matches ey-nginx's `package "nginx"`).
apt_package "clamav-daemon" do
  action :install
end

systemd_unit "clamav-daemon" do
  action :start
end

systemd_unit "clamav-daemon" do
  action :enable
end
