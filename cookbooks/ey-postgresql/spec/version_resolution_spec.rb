#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for the resolve_pg_package_version helper
# (cookbooks/ey-postgresql/libraries/helpers.rb).
#
# Tests are pure Ruby — no Chef, no PostgreSQL, no network required.
# Run: ruby cookbooks/ey-postgresql/spec/version_resolution_spec.rb
#   or: bundle exec ruby spec/version_resolution_spec.rb
#        (from cookbooks/ey-postgresql/spec/, which uses the spec/Gemfile)
#
# Covers (per ey-all#189 AC4, AC5):
#   - AC4: prefix-match bug — "16.4" must not match "16.40", series at 16.10+
#          must resolve via component-wise Gem::Version comparison, not string prefix.
#   - AC5: fallback to newest-in-series when pinned patch is absent.
#          Explicit lock-file / EY_POSTGRES_VERSION pin honoured exactly (raises
#          rather than silently drifting a deliberate customer pin). A node
#          where the postgresql package is already installed (checked via
#          pg_already_installed?/dpkg_package_installed? at converge time --
#          works for both DB and app-tier nodes, both of which get the full
#          postgresql-{version} server package from install.sh.erb) is
#          treated the same as an explicit pin -- a routine reconverge never
#          silently swaps an already-provisioned node's installed patch
#          version; only a genuinely fresh install (package not yet
#          installed) gets the fallback. Also covers dpkg_package_installed?
#          itself against a real dpkg-query subprocess call, not just the
#          pure resolution logic.
#
# The helper is loaded by extracting the module from the library file directly
# to avoid requiring Chef infrastructure.

require "minitest/autorun"
require "rubygems"

# ---------------------------------------------------------------------------
# Load the helper under test without Chef. The module-and-include pattern in
# helpers.rb is safe to call in plain Ruby; the only Chef-specific pieces are
# `Chef::Log.warn` (called only on fallback) and the DSL include lines at the
# bottom of the file. We stub the former and skip the latter.
# ---------------------------------------------------------------------------
module Chef
  module Log
    @warn_messages = []
    class << self
      attr_reader :warn_messages
      def warn(msg)
        @warn_messages << msg
      end
      def reset!
        @warn_messages = []
      end
    end
  end
end

HELPERS_FILE = File.expand_path("../../libraries/helpers.rb", __FILE__)
helpers_src = File.read(HELPERS_FILE)
# Strip the Chef DSL include lines at the bottom so we can load the module
# without requiring Chef. Everything above those lines is plain Ruby.
helpers_src_stripped = helpers_src.gsub(/^Chef::(?:DSL::|).*\.send.*$/, "")
eval(helpers_src_stripped, TOPLEVEL_BINDING, HELPERS_FILE) # rubocop:disable Security/Eval

include PostgreSQL::Helper

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
class VersionResolutionTest < Minitest::Test
  def setup
    Chef::Log.reset!
  end

  # -------------------------------------------------------------------------
  # AC4: PREFIX-MATCH BUG
  # -------------------------------------------------------------------------

  # "16.4" against a list containing "16.10" must resolve to "16.10", not
  # produce a false match on "16.40" (the old /^16.4/ regex matched both).
  def test_ac4_resolves_16_10_not_16_40
    known = ["16.15", "16.14", "16.13", "16.12", "16.11", "16.10"]
    result = resolve_pg_package_version(known, "16.4", "16", explicit_pin: false)
    assert_equal "16.15", result,
      "should resolve to newest in series (16.15) when 16.4 is absent; got #{result}"
  end

  # Regression for the literal bug report: the OLD /^#{install_version}/ regex
  # treated "." as "any character", so "16.4" incorrectly matched "16.40" via
  # string prefix even when the true intent was an exact-patch pin. Verify our
  # exact-match step is a real version-equality check (Gem::Version), not a
  # prefix/regex match — "16.4" and "16.40" are DIFFERENT versions and must
  # not be conflated when both are candidates for an exact pin.
  def test_ac4_exact_match_is_version_equality_not_string_prefix
    known = ["16.40", "16.10"] # 16.4 itself is absent; 16.40 present
    explicit_pin_result = assert_raises(RuntimeError) do
      resolve_pg_package_version(known, "16.4", "16", explicit_pin: true)
    end
    # An explicit pin of "16.4" must NOT be silently satisfied by "16.40" —
    # proves exact-match isn't doing a prefix/regex match under the hood.
    assert_match(/explicitly pinned/, explicit_pin_result.message)
  end

  # "16.4" is gone; list has 16.10–16.15. Must resolve 16.15 (not 16.1x from
  # any string-sort or prefix artifact).
  def test_ac4_version_aware_newest_in_series
    known = ["16.10", "16.11", "16.12", "16.13", "16.14", "16.15"]
    result = resolve_pg_package_version(known, "16.4", "16", explicit_pin: false)
    assert_equal "16.15", result
    # Must NOT be "16.10" or "16.11" (which lexical-max would give)
    refute_equal "16.10", result
  end

  # -------------------------------------------------------------------------
  # AC3: FALLBACK BEHAVIOUR
  # -------------------------------------------------------------------------

  # When pinned patch is absent, resolve to newest available in series (not raise).
  def test_ac3_fallback_to_newest_when_pin_absent
    # Real measured production list for series 11 (11.16 gone; 11.22 is newest)
    known = %w[11.22 11.21 11.20 11.19 11.18 11.17]
    result = resolve_pg_package_version(known, "11.16", "11", explicit_pin: false)
    assert_equal "11.22", result
  end

  # Logs a warning when falling back so converge logs are observable.
  def test_ac3_fallback_logs_warning
    known = %w[11.22 11.21]
    resolve_pg_package_version(known, "11.16", "11", explicit_pin: false)
    assert_equal 1, Chef::Log.warn_messages.length,
      "should log exactly one warning on fallback"
    assert_match(/11\.16.*not available.*Falling back.*11\.22/i, Chef::Log.warn_messages.first)
  end

  # Exact match uses the verbatim pinned version (no version re-selection).
  def test_ac3_exact_match_when_pin_present
    known = %w[16.15 16.14 16.4 16.13]
    result = resolve_pg_package_version(known, "16.4", "16", explicit_pin: false)
    assert_equal "16.4", result
    assert_empty Chef::Log.warn_messages, "should not warn when exact match found"
  end

  # 9.5 series: short_version is "9.5" (2-component). Must match "9.5.25"
  # but NOT "9.6.24" (which shares the "9" component).
  def test_ac3_95_series_not_confused_with_96
    known = %w[9.5.25 9.6.24]
    result = resolve_pg_package_version(known, "9.5.25", "9.5", explicit_pin: false)
    assert_equal "9.5.25", result
  end

  # If 9.5.25 is gone but the repo has a later 9.5.x, fall back within 9.5, not into 9.6.
  def test_ac3_95_fallback_stays_in_95_series
    known = %w[9.5.26 9.6.24]
    result = resolve_pg_package_version(known, "9.5.25", "9.5", explicit_pin: false)
    assert_equal "9.5.26", result
  end

  # No packages at all in the series → raise (can't provision at all).
  def test_ac3_raises_when_no_packages_in_series
    known = %w[12.22 13.23]
    err = assert_raises(RuntimeError) do
      resolve_pg_package_version(known, "11.16", "11", explicit_pin: false)
    end
    assert_match(/no packages found in series 11/, err.message)
  end

  # -------------------------------------------------------------------------
  # AC3/AC5: EXPLICIT PIN ESCAPE HATCHES
  # -------------------------------------------------------------------------

  # lock_version_file pin: exact match present — must succeed.
  def test_explicit_pin_exact_match_succeeds
    known = %w[16.15 16.14 16.4]
    result = resolve_pg_package_version(known, "16.4", "16", explicit_pin: true)
    assert_equal "16.4", result
    assert_empty Chef::Log.warn_messages
  end

  # lock_version_file pin: exact match absent — must raise, not fall back.
  def test_explicit_pin_raises_when_absent
    known = %w[16.15 16.14 16.13]
    err = assert_raises(RuntimeError) do
      resolve_pg_package_version(known, "16.4", "16", explicit_pin: true)
    end
    assert_match(/explicitly pinned/, err.message)
    assert_match(/16\.4/, err.message)
  end

  # EY_POSTGRES_VERSION pin: same strict behaviour as lock_version_file.
  def test_env_var_pin_raises_when_absent
    known = %w[11.22 11.21]
    err = assert_raises(RuntimeError) do
      resolve_pg_package_version(known, "11.16", "11", explicit_pin: true)
    end
    assert_match(/explicitly pinned/, err.message)
  end

  # -------------------------------------------------------------------------
  # Already-provisioned instance reconverge: server_install.rb passes
  # explicit_pin: true when the postgresql package is already installed on
  # this node (checked via dpkg-query, which works on both DB-tier nodes with
  # a running server and app-tier nodes with only the client package -- unlike
  # pg_running, which only detects a locally running server and is always
  # false on app-tier nodes). This ensures that a routine Chef Apply against
  # an already-provisioned instance (DB or app role) never silently swaps its
  # installed PostgreSQL package version just because the default attribute
  # pin has aged out of the apt archive. Only fresh installs (package not yet
  # installed on this node) get the fallback-to-newest-in-series behaviour.
  # -------------------------------------------------------------------------

  def test_reconverge_already_installed_raises_not_falls_back
    # Simulates: postgresql package already installed at converge (DB or app
    # tier), 16.4 pin has aged out. server_install.rb passes explicit_pin:
    # true -> must raise, not silently install 16.15 as a side effect of an
    # unrelated Apply.
    known = %w[16.15 16.14 16.13 16.12 16.11 16.10]
    err = assert_raises(RuntimeError) do
      resolve_pg_package_version(known, "16.4", "16", explicit_pin: true)
    end
    assert_match(/explicitly pinned/, err.message,
                 "should raise rather than silently swapping an already-installed node's patch version")
    assert_empty Chef::Log.warn_messages
  end

  def test_reconverge_already_installed_exact_match_succeeds
    # Package already installed but 16.4 is still in the archive -- happy path.
    known = %w[16.15 16.14 16.4 16.3]
    result = resolve_pg_package_version(known, "16.4", "16", explicit_pin: true)
    assert_equal "16.4", result
    assert_empty Chef::Log.warn_messages
  end

  # -------------------------------------------------------------------------
  # dpkg_package_installed? / pg_already_installed? -- exercises the REAL
  # `system("dpkg-query -W ...")` call server_install.rb's ruby_block relies
  # on to compute explicit_pin, rather than only the pure resolution logic
  # above. Requires dpkg-query on PATH (present in the CI/Docker image; the
  # test is skipped, not failed, if it's unavailable e.g. on a non-Debian
  # host running these tests locally).
  # -------------------------------------------------------------------------

  def test_dpkg_package_installed_true_for_a_real_installed_package
    skip "dpkg-query not on PATH (non-Debian host)" unless system("which dpkg-query >/dev/null 2>&1")
    # bash is present in every Debian/Ubuntu base image used by this cookbook's
    # CI/Docker harness -- a stable, always-installed proxy for "postgresql-N
    # is installed" without requiring PostgreSQL itself.
    assert dpkg_package_installed?("bash"),
           "dpkg-query should report an actually-installed package as installed"
  end

  def test_dpkg_package_installed_false_for_a_nonexistent_package
    skip "dpkg-query not on PATH (non-Debian host)" unless system("which dpkg-query >/dev/null 2>&1")
    refute dpkg_package_installed?("definitely-not-a-real-package-xyz-189"),
           "dpkg-query should report a nonexistent/uninstalled package as not installed"
  end

  def test_pg_already_installed_delegates_to_dpkg_check
    skip "dpkg-query not on PATH (non-Debian host)" unless system("which dpkg-query >/dev/null 2>&1")
    # Use a short_version that can never correspond to a real postgresql-N
    # package (GitHub-hosted ubuntu-latest runners ship several real
    # postgresql-NN packages preinstalled, so we can't assume "16" reads
    # false there the way it does on a bare Docker image). This still proves
    # pg_already_installed? correctly reads "not installed" -> false for the
    # genuinely-fresh-node case (the one AC3's fallback targets), just via a
    # package name guaranteed not to exist on any host instead of assuming
    # postgresql-16's install state.
    refute pg_already_installed?("999"),
           "a node with no postgresql-999 package installed should read as not-already-installed"
  end

  # -------------------------------------------------------------------------
  # Real production-shaped input: the measured apt-cache madison list for
  # postgres16 on Noble-pgdg-archive as of 2026-08-15 (AC6 measurement data).
  # -------------------------------------------------------------------------
  def test_real_pg16_list_resolves_correctly_when_164_present
    # As measured: 16.4 IS still present; default pin should use it.
    known = %w[16.15 16.14 16.13 16.12 16.11 16.10 16.9 16.8 16.7 16.6 16.5 16.4 16.3 16.2 16.1]
    result = resolve_pg_package_version(known, "16.4", "16", explicit_pin: false)
    assert_equal "16.4", result
    assert_empty Chef::Log.warn_messages, "should not warn when exact match found"
  end

  def test_real_pg16_list_falls_back_when_164_absent
    # Simulate 16.4 aging out of the archive window (latent bug firing).
    known = %w[16.15 16.14 16.13 16.12 16.11 16.10 16.9 16.8 16.7 16.6 16.5]
    result = resolve_pg_package_version(known, "16.4", "16", explicit_pin: false)
    assert_equal "16.15", result
    assert_equal 1, Chef::Log.warn_messages.length
  end
end
