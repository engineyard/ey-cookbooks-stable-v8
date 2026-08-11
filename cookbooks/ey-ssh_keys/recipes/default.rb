ey_cloud_report "ssh keys" do
  message "processing ssh keys"
end

directory "/home/#{node['owner_name']}/.ssh" do
  owner node["owner_name"]
  group node["owner_name"]
  mode "0755"
end

[
  {
    ssh_dir: "/home/#{node['owner_name']}/.ssh",
    owner: node["owner_name"],
  }, {
    ssh_dir: "/root/.ssh",
    owner: "root",
  }
].each do |ssh_info|
  ssh_dir = ssh_info[:ssh_dir]
  ssh_owner = ssh_info[:owner]

  ruby_block "copy-ssh-keys-for-#{ssh_owner}" do
    block do
      keys = [node["dna"]["user_ssh_key"]].flatten
      keys << node["dna"]["admin_ssh_key"].to_s

      # Restrict the internal SSH key to the instance's VPC CIDR via an SSH
      # `from="<cidr>"` clause. The CIDR comes from EC2 instance metadata, keyed
      # by the primary NIC's MAC (derived locally from `ip address`, excluding
      # the docker bridge 02:42 MAC) — same derivation as before.
      #
      # Stack v8 (Ubuntu 24.04 / Noble) defaults to IMDSv2-required
      # (HttpTokens=required), under which a plain unauthenticated IMDSv1 GET
      # returns 401. So first acquire an IMDSv2 session token, then pass it on
      # the metadata GET via the X-aws-ec2-metadata-token header. If the token
      # PUT fails, the header is omitted and the GET is a plain IMDSv1 GET
      # (IMDSv2 is available regardless of HttpTokens mode, so in practice this
      # fallback covers a genuine handshake failure, not any particular stack).
      # The metadata GET uses `curl -f`, so a non-200 (e.g. an unauthenticated
      # 401) fails with empty stdout instead of silently capturing the error
      # body — the previous bug, which embedded the 401 body into authorized_keys.
      #
      # All external commands run via Mixlib::ShellOut with an argv array (no
      # intervening shell, so the network-fetched token / MAC are never re-parsed
      # by a shell) — the established pattern in this cookbook tree and what
      # keeps the dynamic values out of a `...` subshell.
      #
      # Because a failed fetch now fail-closes (the internal key is omitted, see
      # below), retry a few times so a transient IMDS blip (boot-time NIC race,
      # brief network hiccup) does not drop the internal access key on an
      # otherwise-healthy instance. On a real IMDSv2-required host the happy path
      # succeeds on the first attempt.
      base = "http://169.254.169.254"

      # MAC of the primary NIC, derived locally (unchanged idiom). Static command
      # string with no interpolation, so it is not a "dangerous subshell".
      mac = Mixlib::ShellOut.new(
        "bash", "-c",
        %q{ip address | grep -m 1 "ether\s.*\ brd\s*" | awk '{print $2}' | grep -v "02:42"}
      ).run_command.stdout.strip

      vpc_cidr = ""
      3.times do |attempt|
        token_out = Mixlib::ShellOut.new(
          "curl", "-s", "-f", "--connect-timeout", "5", "--max-time", "5",
          "-X", "PUT", "#{base}/latest/api/token",
          "-H", "X-aws-ec2-metadata-token-ttl-seconds: 21600"
        ).run_command
        imds_token = token_out.exitstatus.zero? ? token_out.stdout.strip : ""

        cidr_args = ["curl", "-s", "-f", "--connect-timeout", "5", "--max-time", "5"]
        cidr_args += ["-H", "X-aws-ec2-metadata-token: #{imds_token}"] unless imds_token.empty?
        cidr_args << "#{base}/latest/meta-data/network/interfaces/macs/#{mac}/vpc-ipv4-cidr-block"
        cidr_out = Mixlib::ShellOut.new(*cidr_args).run_command
        vpc_cidr = cidr_out.exitstatus.zero? ? cidr_out.stdout.strip : ""

        break unless vpc_cidr.empty?
        sleep 2 unless attempt == 2
      end

      # Fail-closed: validate the fetched value is a CIDR. If it is empty or not
      # a CIDR (fetch failed / corrupt), OMIT the internal key rather than write
      # a malformed `from=` clause — a bad metadata response can never produce a
      # corrupt access-control line.
      if vpc_cidr =~ %r{\A\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}\z}
        keys << %(from="#{vpc_cidr}" #{node['dna']['internal_ssh_public_key']}).to_s
      else
        Chef::Log.error("ey-ssh_keys: could not fetch a valid VPC CIDR from instance metadata (got #{vpc_cidr.inspect}); omitting the internal SSH key rather than writing an unrestricted or corrupt from= clause")
      end

      File.open("#{ssh_dir}/authorized_keys.tmp", "w") do |temp_key_file|
        keys.each do |key|
          temp_key_file.write(key.chomp)
          temp_key_file.write("\n")
        end

        if File.exist?("#{ssh_dir}/extra_authorized_keys")
          File.open("#{ssh_dir}/extra_authorized_keys", "r") do |extra_keys|
            extra_keys.each_line do |extra_key|
              temp_key_file.write(extra_key)
            end
          end
        end

        passwd_entry = Etc.getpwnam(ssh_info[:owner])
        temp_key_file.chown(passwd_entry.uid, passwd_entry.gid)
        temp_key_file.chmod(0600)
      end

      File.rename("#{ssh_dir}/authorized_keys.tmp", "#{ssh_dir}/authorized_keys")
    end
  end

  template "#{ssh_dir}/internal" do
    owner ssh_owner
    group ssh_owner
    mode "0600"
    source "ssh.erb"
    variables({
        key: node["dna"]["internal_ssh_private_key"],
      })
  end
end