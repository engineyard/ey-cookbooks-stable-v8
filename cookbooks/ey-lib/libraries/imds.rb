require "net/http"
require "open-uri"

# EC2 Instance Metadata Service (IMDS) helper.
#
# Ubuntu 24.04 (Noble) base AMIs carry the `imds-support=v2.0` attribute, so
# Stack v8 instances default to IMDSv2-required (HttpTokens=required). Under
# that mode a plain unauthenticated IMDSv1 GET returns 401 Unauthorized. So we
# try the IMDSv2 token handshake first (PUT a session token, then GET with the
# token header) and fall back to a plain unauthenticated GET only when the
# token PUT fails. IMDSv2 is available on all EC2 instances regardless of the
# HttpTokens mode, so in practice the fallback is exercised on a genuine
# handshake/network failure rather than on any particular stack; it is what
# keeps IMDSv1-optional stacks (v5/v6/v7) working while unblocking v8.
#
# Mirrors the enzyme fix.
module EY
  module IMDS
    # IMDS is only reachable over plain HTTP on the link-local 169.254.169.254
    # address; AWS provides no HTTPS endpoint for it, so http:// here is by
    # design, not a downgrade.
    BASE = "http://169.254.169.254".freeze
    TOKEN_TTL = "21600".freeze # 6h, matches the enzyme fix convention

    module_function

    # Fetch a metadata value at `path` (e.g. "latest/meta-data/instance-type").
    # Uses an IMDSv2 token when one can be acquired, otherwise falls back to a
    # plain IMDSv1 GET. Raises on a genuine fetch failure (loud, as before) so
    # callers that relied on the previous fail-loud behaviour are unchanged.
    def get(path)
      token = token()
      headers = token ? { "X-aws-ec2-metadata-token" => token } : {}
      URI.open("#{BASE}/#{path}", headers, &:read) # nosemgrep: problem-based-packs.insecure-transport.ruby-stdlib.net-http-request.net-http-request
    end

    # Request an IMDSv2 session token. Returns the token string, or nil if the
    # PUT fails (network error / genuinely IMDSv1-only environment) so the
    # caller can fall back to an unauthenticated GET.
    def token
      uri = URI("#{BASE}/latest/api/token") # nosemgrep: problem-based-packs.insecure-transport.ruby-stdlib.net-http-request.net-http-request
      req = Net::HTTP::Put.new(uri)
      req["X-aws-ec2-metadata-token-ttl-seconds"] = TOKEN_TTL
      res = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 5, read_timeout: 5) do |http|
        http.request(req)
      end
      res.is_a?(Net::HTTPSuccess) ? res.body : nil
    rescue StandardError
      nil
    end
  end
end
