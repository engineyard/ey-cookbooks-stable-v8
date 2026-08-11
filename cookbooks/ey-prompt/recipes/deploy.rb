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
# Must fail loud on an error response: the fetched value is interpolated into
# the shell prompt. Net::HTTP.get would return a non-200 body (e.g. a 401 error
# page under IMDSv2) as if it were the value, silently corrupting the prompt.
# URI.open raises OpenURI::HTTPError on any non-2xx, so an auth/server error
# aborts rather than corrupts. A 404 is treated as legitimate absence (the key
# is not set, e.g. no public IPv4/hostname) and returns nil, preserving the
# original "if assigned" tolerance.
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
  # auth failure, 5xx) is a real error we must NOT swallow into the prompt.
  return nil if e.io.status.first == "404"
  raise
end

# Grab the public hostname for this instance. This recipe
# will be run *from* the instance, which means that the following
# IP address will be resolved internally from Amazon, which
# is good because it's an Amazon-specific, internal IP
# that they use for instance metadata.
public_hostname = imds_get("latest/meta-data/public-hostname")
# Getting public IP address if assigned
public_ip_address = imds_get("latest/meta-data/public-ipv4")
# Specify the users you want to have this prompt in this array.
# users = [""]

users = []
users << node.engineyard.environment.ssh_username

# This recipe needs to be in a ruby_block because Chef is running in an
# indeterminate order. Don't know which piece runs when, and notifies just
# plain sucks because it doesn't work.
ruby_block :source_prompt do
  block do
    # Write out the prompt file and update ~/.bashrc for each user
    users.each do |u|
      # Put something in the Chef log
      STDOUT.puts "Setting up better bash prompt for user: #{u} ..."

      # Root has a different path for its homedir than other users might,
      # so find this user's home directory
      homedir = `echo /home/#{u}`.chomp

      STDOUT.puts "Found home directory #{homedir} for #{u} ..."

      # If the user doesn't have a .bashrc for some reason, this is going
      # to fail miserably. Check for it and if it's not there, look in
      # /etc/skel/.bashrc. If that isn't there, create a blank file.
      unless File.exist?("#{homedir}/.bashrc")
        # Not there - is it in /etc/skel/.bashrc?
        if File.exist?("/etc/skel/.bashrc")
          `cp /etc/skel/.bashrc #{homedir}/.bashrc`
        else
          `touch #{homedir}/.bashrc`
        end
      end

      # Tell .bashrc to 'source' this file unless it already does
      unless File.read("#{homedir}/.bashrc").match(/\.prompt/)
        File.open("#{homedir}/.bashrc", "a+") do |f|
          f.puts "source ~/.prompt"
        end
      end
    end # end users loop
  end # end block
end # end chef ruby_block

users.each do |u|
  homedir = `echo /home/#{u}`.chomp
  # Write out ~/.prompt which then gets sourced by ~/.bashrc
  template "#{homedir}/.prompt" do
    action :create
    owner  u
    group  u
    mode   "0640"
    source "prompt.erb"
    variables({
      user: u,
      role: !node["dna"]["name"].nil? ? node["dna"]["name"] : node["instance_role"],
      env_name: node["environment_name"],
      app_type: node["application_type"],
      env_framework: node["dna"]["environment"]["framework_env"],
      public_hostname: public_hostname,
      public_ip: public_ip_address,
    })
  end
end
