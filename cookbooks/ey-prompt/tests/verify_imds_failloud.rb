#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Re-runnable, self-contained verification for the fail-loud inline `imds_get`
# helper used by both ey-prompt/recipes/deploy.rb and
# ey-fail2ban/recipes/jails.rb.
#
# The helper must, on a non-200 IMDS response, RAISE rather than return the
# error body (the silent-corruption bug this fix eliminates) — EXCEPT a 404, which
# is legitimate absence (no public IPv4/hostname) and returns nil. This script
# reproduces the helper's exact core (URI.open + the 404-tolerant rescue) and
# proves 200/404/401 behaviour against a local server, under ruby:3.0 (Chef 17's
# embedded Ruby).
#
# Run:
#   docker run --rm -v "$PWD":/w -w /w ruby:3.0 \
#     ruby cookbooks/ey-prompt/tests/verify_imds_failloud.rb
#
# Exits 0 on success, 1 on failure.

require "socket"
require "open-uri"

# The recipe's fail-loud read core (identical to the URI.open + rescue in
# ey-prompt/deploy.rb and ey-fail2ban/jails.rb). No token handshake here — that
# path is verified separately; this isolates the status-handling contract.
def imds_read(url)
  URI.open(url, {}, &:read)
rescue OpenURI::HTTPError => e
  return nil if e.io.status.first == "404"
  raise
end

failures = []
def check(desc, cond, failures)
  ok = !!cond
  puts format("  [%s] %s", ok ? "PASS" : "FAIL", desc)
  failures << desc unless ok
  ok
end

srv = TCPServer.new("127.0.0.1", 0)
port = srv.addr[1]
Thread.new do
  loop do
    cl = srv.accept
    path = cl.gets.to_s.split(" ")[1].to_s
    code, body = case path
                 when "/ok" then [200, "ec2-1-2-3-4.compute-1.amazonaws.com"]
                 when "/absent" then [404, "<html>404 Not Found</html>"]
                 else [401, "<html>401 Unauthorized</html>"]
                 end
    reason = { 200 => "OK", 404 => "Not Found", 401 => "Unauthorized" }[code]
    cl.write "HTTP/1.1 #{code} #{reason}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
    while (line = cl.gets) && line != "\r\n"; end
    cl.close
  end
end
sleep 0.3
base = "http://127.0.0.1:#{port}"

puts "imds_get fail-loud contract:"
check("200 -> returns the value", imds_read("#{base}/ok") == "ec2-1-2-3-4.compute-1.amazonaws.com", failures)
check("404 -> returns nil (legitimate absence, no converge abort)", imds_read("#{base}/absent").nil?, failures)

raised =
  begin
    imds_read("#{base}/auth")
    false
  rescue OpenURI::HTTPError
    true
  end
check("401 -> raises OpenURI::HTTPError (fail-loud; error body NOT returned)", raised, failures)

puts "\n#{failures.empty? ? "ALL PASS" : "#{failures.size} FAILURE(S)"}"
exit(failures.empty? ? 0 : 1)
