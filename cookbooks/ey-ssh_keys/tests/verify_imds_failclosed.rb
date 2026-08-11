#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Re-runnable, self-contained verification for the ey-ssh_keys fail-closed
# IMDS fetch. This repo has no test-kitchen / rspec
# harness, and Ruby is not run locally (old-Ruby-on-Apple-Silicon), so this is
# a plain-Ruby script exercising the two load-bearing correctness properties
# with the RECIPE'S OWN regex (read from source, not a copy):
#
#   1. The CIDR validation regex accepts only well-formed IPv4 CIDRs and
#      rejects empty / error-body / bare-IP values — so a non-200 IMDS body can
#      never reach the `from="..."` access-control clause.
#   2. `curl -s -f` against a non-200 yields empty stdout + nonzero exit — the
#      mechanism the recipe relies on so a 401 body is never captured.
#
# Run (matches Chef 17's embedded Ruby 3.0):
#   docker run --rm -v "$PWD":/w -w /w ruby:3.0 \
#     ruby cookbooks/ey-ssh_keys/tests/verify_imds_failclosed.rb
#
# Exits 0 on success, 1 on any failure (usable as a CI gate if one is added).

require "socket"

RECIPE = File.expand_path("../recipes/default.rb", __dir__)

failures = []
def check(desc, cond, failures)
  ok = !!cond
  puts format("  [%s] %s", ok ? "PASS" : "FAIL", desc)
  failures << desc unless ok
  ok
end

# --- 1. Extract the CIDR regex from the recipe itself -----------------------
# Binds the test to the real pattern: if the recipe regex changes, this does too.
# The recipe writes it as a %r{...} literal whose body itself contains braces
# (\d{1,3}), so match the single `vpc_cidr =~ %r{...}` line greedily to the last
# brace and rebuild the Regexp from the captured source (no eval).
src_line = File.readlines(RECIPE).find { |l| l =~ /vpc_cidr\s*=~\s*%r\{/ }
abort "Could not locate the CIDR validation regex in #{RECIPE}" unless src_line
body = src_line.match(/%r\{(.*)\}/)[1]
cidr_re = Regexp.new(body)
puts "Recipe CIDR regex: #{cidr_re.inspect}"

puts "\nCIDR accept/reject table:"
accept = ["10.0.0.0/16", "172.31.16.0/20", "192.168.0.0/24", "10.0.0.0/8"]
reject = ["", "Unauthorized",
          "<?xml version=\"1.0\"?><Error><Code>401</Code></Error>",
          "10.0.0.5",                # bare IP, no mask
          "not-a-cidr",
          "10.0.0.0/16\n10.0.0.0/16"] # multi-line body
accept.each { |v| check("accepts #{v.inspect}", v =~ cidr_re, failures) }
reject.each { |v| check("rejects #{v.inspect}", !(v =~ cidr_re), failures) }

# --- 2. curl -s -f fail-closed against a non-200 ----------------------------
puts "\ncurl -s -f fail-closed behaviour:"
srv = TCPServer.new("127.0.0.1", 0)
port = srv.addr[1]
Thread.new do
  loop do
    cl = srv.accept
    req = cl.gets.to_s
    path = req.split(" ")[1].to_s
    if path == "/ok"
      body = "10.0.0.0/16"
      cl.write "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
    else
      body = "Unauthorized"
      cl.write "HTTP/1.1 401 Unauthorized\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
    end
    while (line = cl.gets) && line != "\r\n"; end
    cl.close
  end
end
sleep 0.3

def curl_f(url)
  out = `curl -s -f --connect-timeout 5 --max-time 5 #{url} 2>/dev/null`
  [out, $?.exitstatus]
end

ok_out, ok_code = curl_f("http://127.0.0.1:#{port}/ok")
check("200 -> captures the value", ok_out == "10.0.0.0/16" && ok_code.zero?, failures)

bad_out, bad_code = curl_f("http://127.0.0.1:#{port}/auth")
check("401 -> empty stdout (body NOT captured)", bad_out.empty?, failures)
check("401 -> nonzero exit (fetch treated as failure)", !bad_code.zero?, failures)

# Compose the two: a 401 fetch yields "" which the regex rejects -> key omitted.
vpc_cidr = bad_out.strip
check("401 fetch result fails CIDR validation -> internal key omitted",
      !(vpc_cidr =~ cidr_re), failures)

puts "\n#{failures.empty? ? "ALL PASS" : "#{failures.size} FAILURE(S)"}"
exit(failures.empty? ? 0 : 1)
