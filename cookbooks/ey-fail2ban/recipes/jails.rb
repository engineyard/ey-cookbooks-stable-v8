# We need net/http (token PUT) and open-uri (fail-loud GET) for IMDS.
require "net/http"
require "open-uri"

# Fetch an EC2 instance metadata value using IMDSv2 (token handshake) with a
# plain-GET fallback. Stack v8 (Ubuntu 24.04 / Noble) defaults to IMDSv2-required
# (HttpTokens=required), under which a plain unauthenticated IMDSv1 GET returns
# 401. If the token PUT fails we fall back to an unauthenticated GET; IMDSv2 is
# available regardless of HttpTokens mode, so in practice the fallback covers a
# genuine handshake failure while keeping IMDSv1-optional stacks (v5/v6/v7)
# working. Mirrors the enzyme fix.
#
# IMPORTANT: this MUST fail loud on an error response. The fetched value flows
# into fail2ban's `ignoreip` allow-list; if a non-200 body (e.g. a 401 error
# page under IMDSv2) were returned as if it were the value, it would silently
# corrupt the ban-exemption list. `URI.open` raises OpenURI::HTTPError on any
# non-2xx, so an auth/server error aborts the converge instead of poisoning
# config. Do NOT use Net::HTTP.get here — it returns the body regardless of
# status. A 404 is treated as legitimate absence (the metadata key is not set,
# e.g. an instance with no public IPv4) and returns nil, preserving the original
# "if assigned" tolerance.
def imds_get(path)
  # IMDS is only reachable over plain HTTP on the link-local 169.254.169.254
  # address; AWS provides no HTTPS endpoint for it, so http:// here is by
  # design, not a downgrade. Suppress Semgrep's insecure-transport rule.
  base = "http://169.254.169.254"
  token = begin
    uri = URI("#{base}/latest/api/token") # nosemgrep: problem-based-packs.insecure-transport.ruby-stdlib.net-http-request.net-http-request
    req = Net::HTTP::Put.new(uri)
    req["X-aws-ec2-metadata-token-ttl-seconds"] = "21600"
    res = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 5, read_timeout: 5) do |http|
      http.request(req)
    end
    res.is_a?(Net::HTTPSuccess) ? res.body : nil
  rescue StandardError
    nil
  end
  headers = token ? { "X-aws-ec2-metadata-token" => token } : {}
  URI.open("#{base}/#{path}", headers, &:read) # nosemgrep: problem-based-packs.insecure-transport.ruby-stdlib.net-http-request.net-http-request
rescue OpenURI::HTTPError => e
  # 404 = key legitimately absent (e.g. no public IPv4). Anything else (401/403
  # auth failure, 5xx) is a real error we must NOT swallow into config.
  return nil if e.io.status.first == "404"
  raise
end

# Basic IPv4 sanity check, so a malformed value can never reach `ignoreip`.
IPV4_RE = /\A\d{1,3}(?:\.\d{1,3}){3}\z/

ey_cloud_report "Fail2Ban-filter-action" do
  message "Fail2Ban action & filter"
end

public_ip = imds_get("latest/meta-data/public-ipv4").to_s.strip
# A present-but-malformed value is a corruption signal → fail loud. An empty
# value means no public IPv4 is assigned (404 above) → simply omit it from
# ignoreip rather than appending garbage.
raise "ey-fail2ban: IMDS returned a malformed public-ipv4 (#{public_ip.inspect})" unless public_ip.empty? || public_ip =~ IPV4_RE

def pushFile(fileList, type)
  refPath = "#{Chef::Config['file_cache_path']}/cookbooks/ey-fail2ban/files"
  files = fileList.select { |w| w[/#{type}\.d/] }
  files.each do |filepath|
    filename = filepath.match(/#{refPath}\/.*\/#{type}\.d\/(.*)/)
    filename = "#{type}.d/#{filename[1]}"
    cookbook_file "/etc/fail2ban/#{filename}" do
      source filename # filename instead of filepath in the case of a platform specific stuff
      owner "root"
      group "root"
      mode "644"
      action :create # :create_if_missing
    end
  end
end

def pushFileTemplates(fileList, type)
  refPath = "#{Chef::Config['file_cache_path']}cookbooks/fail2ban/templates"
  files = fileList.select { |w| w[/#{type}\.d/] }
  files.each do |filepath|
    filename = filepath.match(/#{refPath}\/.*\/#{type}\.d\/(.*)/)
    filename = "#{type}.d/#{filename[1]}"
    template "/etc/fail2ban/#{filename}" do
      source filename
      owner "root"
      group "root"
      mode "0644"
      variables({
        public_ip: public_ip,
        private_ip: node["ipaddress"],
        host: node["hostname"],
      })
      action :create # :create_if_missing
    end
  end
end

# list file to upload for action and filter try for the templates too
# @see http://lists.opscode.com/sympa/arc/chef/2011-09/msg00271.html
# files = run_context.cookbook_collection[ cookbook_name ].template_filenames
# pushFileTemplates(files, "filter")
# pushFileTemplates(files, "action")
files = run_context.cookbook_collection[ cookbook_name ].all_files
pushFile(files, "filter")
pushFile(files, "action")

#
# Now that we have filter and action deployed, we can configure the jail
#

ey_cloud_report "Fail2Ban-jail-conf" do
  message "Fail2Ban jails"
  Chef::Log.info "Fail2Ban jails configuration"
end

template "/etc/fail2ban/jail.local" do
  source "jail.local.erb"
  action :create
  variables({
    jails: node["fail2ban"]["jails"]["jails"],
    ignoreip: node["fail2ban"]["jails"]["ignoreip"] + " " + node["ipaddress"] + " " + public_ip,
    bantime: node["fail2ban"]["jails"]["bantime"],
    findtime: node["fail2ban"]["jails"]["findtime"],
    maxretry: node["fail2ban"]["jails"]["maxretry"],
    backend: node["fail2ban"]["jails"]["backend"],
    mail: node["fail2ban"]["jails"]["mail"],
    usedns: node["fail2ban"]["jails"]["usedns"],
    ignorecommand: node["fail2ban"]["jails"]["ignorecommand"],
    host: node["hostname"],
    actions: node["fail2ban"]["jails"]["actions"],
    banaction: node["fail2ban"]["jails"]["banaction"],
    mta: node["fail2ban"]["jails"]["mta"],
    protocol: node["fail2ban"]["jails"]["protocol"],
  })
  owner "root"
  group "root"
  mode "644"
  notifies :restart, "service[fail2ban]"
end

# http://serverfault.com/questions/460442/chef-multiple-files-dynamic-template-resource
# http://docs.getchef.com/chef/dsl_recipe.html
