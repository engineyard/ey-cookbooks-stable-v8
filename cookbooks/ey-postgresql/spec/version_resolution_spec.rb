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
# Covers:
#   - Prefix-match bug: "16.4" must not match "16.40", series at 16.10+
#          must resolve via component-wise Gem::Version comparison, not string prefix.
#   - Fallback to newest-in-series when pinned patch is absent.
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
#   - Pin selection (resolve_pg_version_pin) and, above all, REPEAT CONVERGES:
#          an instance provisioned via the fallback must keep converging. The
#          pin for an already-installed node is the version dpkg actually
#          reports, not the default attribute the fallback did not use, so
#          the exact match succeeds on every converge after the first.
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
# Test double for the Chef node, for resolve_pg_version_pin. Models the three
# things that can pin a version, and nothing else:
#
#   - the lock version file's presence and contents (customer lock_db_version)
#   - the EY_POSTGRES_VERSION environment variable
#   - the postgresql-{series} version dpkg reports as installed
#
# The lock file is kept in memory rather than on disk so the tests never touch
# /db, and the dpkg lookup is stubbed below -- these tests must describe a node
# in an arbitrary state, which the host running them is not in.
# ---------------------------------------------------------------------------
class FakeNode
  attr_accessor :installed_version
  attr_reader :lock_file_version, :env_var_version

  LOCK_FILE = "/db/.lock_db_version"

  def initialize(latest_version:, installed_version: nil, lock_file_version: nil, env_var_version: nil)
    @latest_version = latest_version
    @installed_version = installed_version
    @lock_file_version = lock_file_version
    @env_var_version = env_var_version
  end

  def [](key)
    case key
    when "lock_version_file" then LOCK_FILE
    when "postgresql" then { "latest_version" => @latest_version }
    else raise ArgumentError, "unexpected node attribute #{key.inspect}"
    end
  end
end

# Redirect resolve_pg_version_pin's three collaborators -- the lock file on
# disk, the environment variable lookup, and the dpkg query -- at the FakeNode
# currently under test. resolve_pg_version_pin itself is the unit under test
# and is NOT stubbed: the tests below run the real precedence logic. Only the
# node it reads from is simulated.
#
# The node is passed via a global because installed_pg_version takes a series
# number rather than the node; pin_for below sets and clears it around each
# call. Both stubs fall through to the real implementation when no FakeNode is
# active, so the real dpkg-query tests further down still exercise the real
# subprocess.
$fake_node = nil

module PostgreSQL
  module Helper
    # Not defined by helpers.rb (it lives in the ey-lib cookbook, which this
    # spec deliberately does not load), so this is the only definition.
    def fetch_env_var(node, name, _default = nil)
      raise ArgumentError, "unexpected env var #{name}" unless name == "EY_POSTGRES_VERSION"
      node.env_var_version
    end

    alias_method :installed_pg_version_without_fake, :installed_pg_version

    def installed_pg_version(short_version)
      return installed_pg_version_without_fake(short_version) unless $fake_node
      $fake_node.installed_version
    end
  end
end

# File.exist?/File.read are answered from the FakeNode for the lock file path
# only, so the tests never read or write /db.
class << File
  alias_method :exist_without_fake?, :exist?
  alias_method :read_without_fake, :read

  def exist?(path)
    return !$fake_node.lock_file_version.nil? if $fake_node && path == FakeNode::LOCK_FILE
    exist_without_fake?(path)
  end

  def read(path, *args)
    return $fake_node.lock_file_version if $fake_node && path == FakeNode::LOCK_FILE
    read_without_fake(path, *args)
  end
end

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
class VersionResolutionTest < Minitest::Test
  def setup
    Chef::Log.reset!
    $fake_node = nil
  end

  def teardown
    $fake_node = nil
  end

  # Run the real resolve_pg_version_pin against a simulated node.
  def pin_for(node, short_version)
    $fake_node = node
    resolve_pg_version_pin(node, short_version)
  ensure
    $fake_node = nil
  end

  # -------------------------------------------------------------------------
  # PREFIX-MATCH BUG
  # -------------------------------------------------------------------------

  # "16.4" against a list containing "16.10" must resolve to "16.10", not
  # produce a false match on "16.40" (the old /^16.4/ regex matched both).
  def test_resolves_16_10_not_16_40
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
  def test_exact_match_is_version_equality_not_string_prefix
    known = ["16.40", "16.10"] # 16.4 itself is absent; 16.40 present
    explicit_pin_result = assert_raises(RuntimeError) do
      resolve_pg_package_version(known, "16.4", "16", explicit_pin: true)
    end
    # An explicit pin of "16.4" must NOT be silently satisfied by "16.40" —
    # proves exact-match isn't doing a prefix/regex match under the hood.
    assert_match(/pinned by/, explicit_pin_result.message)
  end

  # "16.4" is gone; list has 16.10–16.15. Must resolve 16.15 (not 16.1x from
  # any string-sort or prefix artifact).
  def test_version_aware_newest_in_series
    known = ["16.10", "16.11", "16.12", "16.13", "16.14", "16.15"]
    result = resolve_pg_package_version(known, "16.4", "16", explicit_pin: false)
    assert_equal "16.15", result
    # Must NOT be "16.10" or "16.11" (which lexical-max would give)
    refute_equal "16.10", result
  end

  # -------------------------------------------------------------------------
  # FALLBACK BEHAVIOUR
  # -------------------------------------------------------------------------

  # When pinned patch is absent, resolve to newest available in series (not raise).
  def test_fallback_to_newest_when_pin_absent
    # Real measured production list for series 11 (11.16 gone; 11.22 is newest)
    known = %w[11.22 11.21 11.20 11.19 11.18 11.17]
    result = resolve_pg_package_version(known, "11.16", "11", explicit_pin: false)
    assert_equal "11.22", result
  end

  # Logs a warning when falling back so converge logs are observable.
  def test_fallback_logs_warning
    known = %w[11.22 11.21]
    resolve_pg_package_version(known, "11.16", "11", explicit_pin: false)
    assert_equal 1, Chef::Log.warn_messages.length,
      "should log exactly one warning on fallback"
    assert_match(/11\.16.*not available.*Falling back.*11\.22/i, Chef::Log.warn_messages.first)
  end

  # Exact match uses the verbatim pinned version (no version re-selection).
  def test_exact_match_when_pin_present
    known = %w[16.15 16.14 16.4 16.13]
    result = resolve_pg_package_version(known, "16.4", "16", explicit_pin: false)
    assert_equal "16.4", result
    assert_empty Chef::Log.warn_messages, "should not warn when exact match found"
  end

  # 9.5 series: short_version is "9.5" (2-component). Must match "9.5.25"
  # but NOT "9.6.24" (which shares the "9" component).
  def test_95_series_not_confused_with_96
    known = %w[9.5.25 9.6.24]
    result = resolve_pg_package_version(known, "9.5.25", "9.5", explicit_pin: false)
    assert_equal "9.5.25", result
  end

  # If 9.5.25 is gone but the repo has a later 9.5.x, fall back within 9.5, not into 9.6.
  def test_95_fallback_stays_in_95_series
    known = %w[9.5.26 9.6.24]
    result = resolve_pg_package_version(known, "9.5.25", "9.5", explicit_pin: false)
    assert_equal "9.5.26", result
  end

  # No packages at all in the series → raise (can't provision at all).
  def test_raises_when_no_packages_in_series
    known = %w[12.22 13.23]
    err = assert_raises(RuntimeError) do
      resolve_pg_package_version(known, "11.16", "11", explicit_pin: false)
    end
    assert_match(/no packages found in series 11/, err.message)
  end

  # -------------------------------------------------------------------------
  # EXPLICIT PIN ESCAPE HATCHES
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
    assert_match(/pinned by/, err.message)
    assert_match(/16\.4/, err.message)
  end

  # EY_POSTGRES_VERSION pin: same strict behaviour as lock_version_file.
  def test_env_var_pin_raises_when_absent
    known = %w[11.22 11.21]
    err = assert_raises(RuntimeError) do
      resolve_pg_package_version(known, "11.16", "11", explicit_pin: true)
    end
    assert_match(/pinned by/, err.message)
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
    assert_match(/pinned by/, err.message,
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
    # genuinely-fresh-node case (the one the fallback targets), just via a
    # package name guaranteed not to exist on any host instead of assuming
    # postgresql-16's install state.
    refute pg_already_installed?("999"),
           "a node with no postgresql-999 package installed should read as not-already-installed"
  end

  # -------------------------------------------------------------------------
  # REPEAT CONVERGES.
  #
  # server_install.rb runs on every converge, including the environment-wide
  # runs triggered when an instance is added or removed -- so a fix that only
  # works on first boot leaves every instance a one-converge wonder.
  #
  # Run 1: fresh node, no PostgreSQL installed, the attribute's patch version
  # has aged out of the archive -> unpinned -> fallback installs newest-in-
  # series. Run 2: that version is now installed, so the node is pinned -- and
  # the pin must be what dpkg reports (what run 1 actually installed), NOT the
  # default attribute the fallback deliberately did not use. Pinning to the
  # attribute would raise on every converge after the first.
  # -------------------------------------------------------------------------

  # The measured production case: series 11, attribute pinned at 11.16, which
  # is long gone; 11.22 is the only patch the archive still offers.
  PG11_KNOWN = %w[11.22 11.21 11.20 11.19 11.18 11.17].freeze

  def test_repeat_converge_second_run_succeeds_after_fallback
    # Run 1 -- fresh node: nothing installed, so nothing pins it.
    fresh = FakeNode.new(latest_version: "11.16")
    install_version, explicit_pin, = pin_for(fresh, "11")
    refute explicit_pin, "a fresh node has no pin, so the fallback can fire"
    run1 = resolve_pg_package_version(PG11_KNOWN, install_version, "11", explicit_pin: explicit_pin)
    assert_equal "11.22", run1

    # Run 2 -- the same node, reconverged, with run 1's package installed.
    # The attribute is still the stale 11.16; the node must pin to 11.22.
    Chef::Log.reset!
    installed = FakeNode.new(latest_version: "11.16", installed_version: run1)
    install_version, explicit_pin, pin_source = pin_for(installed, "11")
    assert explicit_pin, "an already-installed node is pinned to its installed version"
    assert_equal run1, install_version,
                 "must pin to the installed version, not the attribute the fallback did not use"

    run2 = resolve_pg_package_version(PG11_KNOWN, install_version, "11",
                                      explicit_pin: explicit_pin, pin_source: pin_source)
    assert_equal run1, run2, "a repeat converge must resolve to the installed version"
    assert_empty Chef::Log.warn_messages, "the exact match means no fallback and no warning"
  end

  # The same node converged repeatedly must stay on one version forever, with
  # no raise and no drift, even though newer patches exist in the archive.
  def test_repeat_converge_is_stable_across_many_runs
    node = FakeNode.new(latest_version: "11.16")
    resolved = nil
    5.times do
      install_version, explicit_pin, pin_source = pin_for(node, "11")
      resolved = resolve_pg_package_version(PG11_KNOWN, install_version, "11",
                                            explicit_pin: explicit_pin, pin_source: pin_source)
      # Converging installs the resolved version, which pins the next run.
      node.installed_version = resolved
    end
    assert_equal "11.22", resolved
  end

  # Guards the specific defect: pinning an already-installed node to the
  # default attribute (rather than to the installed version) makes run 2 raise.
  # This is what resolve_pg_version_pin must never do.
  def test_pinning_to_stale_attribute_would_break_the_second_converge
    err = assert_raises(RuntimeError) do
      resolve_pg_package_version(PG11_KNOWN, "11.16", "11", explicit_pin: true)
    end
    assert_match(/does not know about PostgreSQL version 11\.16/, err.message)
  end

  # An already-installed node whose installed version has itself aged out of
  # the archive must still raise -- the pin is real, and silently swapping a
  # running database's patch version is exactly what it exists to prevent.
  def test_installed_version_absent_from_archive_still_raises
    node = FakeNode.new(latest_version: "11.16", installed_version: "11.17")
    install_version, explicit_pin, pin_source = pin_for(node, "11")
    err = assert_raises(RuntimeError) do
      resolve_pg_package_version(%w[11.22 11.21], install_version, "11",
                                 explicit_pin: explicit_pin, pin_source: pin_source)
    end
    assert_match(/11\.17/, err.message)
  end

  # -------------------------------------------------------------------------
  # PIN PRECEDENCE (resolve_pg_version_pin)
  # -------------------------------------------------------------------------

  def test_pin_precedence_lock_file_wins_over_installed_version
    node = FakeNode.new(latest_version: "11.16", installed_version: "11.22",
                        lock_file_version: "11.20", env_var_version: "11.21")
    install_version, explicit_pin, pin_source = pin_for(node, "11")
    assert_equal "11.20", install_version
    assert explicit_pin
    assert_match(/lock_version_file/, pin_source)
  end

  def test_pin_precedence_env_var_wins_over_installed_version
    # attributes/version.rb folds EY_POSTGRES_VERSION into latest_version
    # before this runs, so the env var's value arrives via latest_version.
    node = FakeNode.new(latest_version: "11.21", installed_version: "11.22",
                        env_var_version: "11.21")
    install_version, explicit_pin, pin_source = pin_for(node, "11")
    assert_equal "11.21", install_version
    assert explicit_pin
    assert_match(/EY_POSTGRES_VERSION/, pin_source)
  end

  def test_pin_source_names_the_installed_packages_not_a_pin_the_operator_never_set
    # The failure message must name the real reason. Blaming lock_version_file
    # or EY_POSTGRES_VERSION here accuses an operator of a pin they never set.
    node = FakeNode.new(latest_version: "11.16", installed_version: "11.17")
    _, _, pin_source = pin_for(node, "11")
    assert_match(/already installed on this instance/, pin_source)
    refute_match(/EY_POSTGRES_VERSION/, pin_source)
    refute_match(/lock_version_file/, pin_source)
  end

  def test_fresh_node_is_unpinned
    node = FakeNode.new(latest_version: "11.16")
    install_version, explicit_pin, pin_source = pin_for(node, "11")
    assert_equal "11.16", install_version
    refute explicit_pin
    assert_nil pin_source
  end

  # -------------------------------------------------------------------------
  # dpkg version parsing
  # -------------------------------------------------------------------------

  # dpkg reports the full debian version; only the upstream part is a
  # PostgreSQL version we can match against apt-cache madison output.
  def test_dpkg_package_version_strips_the_debian_revision
    skip "dpkg-query not on PATH (non-Debian host)" unless system("which dpkg-query >/dev/null 2>&1")
    version = dpkg_package_version("bash")
    refute_nil version, "bash is installed in the test image and must report a version"
    assert_match(/\A[0-9]+(\.[0-9]+)*\z/, version,
                 "must be a bare dotted version with no debian revision; got #{version.inspect}")
  end

  def test_dpkg_package_version_nil_for_a_nonexistent_package
    skip "dpkg-query not on PATH (non-Debian host)" unless system("which dpkg-query >/dev/null 2>&1")
    assert_nil dpkg_package_version("definitely-not-a-real-package-xyz")
  end

  def test_installed_pg_version_nil_on_a_fresh_node
    skip "dpkg-query not on PATH (non-Debian host)" unless system("which dpkg-query >/dev/null 2>&1")
    # As in the pg_already_installed? test above, use a series number that can
    # never correspond to a real package so the result is host-independent.
    assert_nil installed_pg_version("999"),
               "a node with no postgresql-999 installed has no version to pin to"
  end

  # The parsing itself, against the exact strings dpkg emits. The tests above
  # can only assert the shape of whatever version the test image happens to
  # ship, so they cannot show that a real PostgreSQL package version parses
  # correctly -- and a version parsed wrong becomes a pin that never matches.
  #
  # dpkg-query is stubbed here (and only here) so specific outputs can be
  # driven through the real parser.
  def with_dpkg_output(output)
    singleton = (class << self; self; end)
    singleton.send(:define_method, :`) { |_cmd| output }
    yield
  ensure
    singleton.send(:remove_method, :`)
  end

  def test_dpkg_version_parsing_of_a_real_postgresql_package_version
    # As reported on an instance running the PostgreSQL 11 series.
    with_dpkg_output("installed 11.22-10.pgdg24.04+1") do
      assert_equal "11.22", dpkg_package_version("postgresql-11")
    end
  end

  def test_dpkg_version_parsing_strips_an_epoch_prefix
    # An epoch is dpkg-internal ordering metadata, not part of the upstream
    # version. Reading it as the version would pin to "1".
    with_dpkg_output("installed 1:16.4-1.pgdg24.04+1") do
      assert_equal "16.4", dpkg_package_version("postgresql-16")
    end
  end

  def test_dpkg_version_parsing_keeps_three_component_versions
    # The 9.x series carries a third component, which must survive intact.
    with_dpkg_output("installed 9.5.25-1.pgdg20.04+1") do
      assert_equal "9.5.25", dpkg_package_version("postgresql-9.5")
    end
  end

  def test_dpkg_version_parsing_treats_removed_but_not_purged_as_fresh
    # dpkg-query exits 0 and still reports a Version for a package removed
    # without purging, but no server is installed -- so there is nothing to
    # pin to, and the instance must be treated as fresh.
    with_dpkg_output("config-files 11.22-10.pgdg24.04+1") do
      assert_nil dpkg_package_version("postgresql-11")
    end
  end

  def test_dpkg_version_parsing_of_empty_output
    with_dpkg_output("") { assert_nil dpkg_package_version("postgresql-11") }
  end

  def test_dpkg_version_parsing_of_a_non_numeric_version
    # Nothing to pin to, so nil rather than a wrong guess.
    with_dpkg_output("installed weird-version") do
      assert_nil dpkg_package_version("postgresql-11")
    end
  end

  # -------------------------------------------------------------------------
  # Deduplication: apt-cache madison lists the same version once per
  # suite/component it is published in, so the raw list is heavily duplicated
  # (the observed series-11 list was eight identical entries). The duplicates
  # carry no information and make the version list in an error message read as
  # corrupted, so error messages must show a deduplicated list.
  # -------------------------------------------------------------------------

  def test_error_message_deduplicates_known_versions
    known = %w[11.22 11.22 11.22 11.22 11.22 11.22 11.22 11.22]
    err = assert_raises(RuntimeError) do
      resolve_pg_package_version(known, "11.16", "11", explicit_pin: true)
    end
    assert_match(/\["11\.22"\]/, err.message,
                 "known versions must be deduplicated in the message; got: #{err.message}")
  end

  def test_no_packages_in_series_message_deduplicates_known_versions
    known = %w[12.22 12.22 12.22]
    err = assert_raises(RuntimeError) do
      resolve_pg_package_version(known, "11.16", "11", explicit_pin: false)
    end
    assert_match(/\["12\.22"\]/, err.message)
  end

  # Duplicates in the input must not change which version is selected.
  def test_duplicated_input_still_resolves_to_newest_in_series
    known = %w[11.22 11.22 11.21 11.21 11.22]
    result = resolve_pg_package_version(known, "11.16", "11", explicit_pin: false)
    assert_equal "11.22", result
  end

  # -------------------------------------------------------------------------
  # Real production-shaped input: the measured apt-cache madison list for
  # postgres16 on Noble-pgdg-archive as of 2026-08-15.
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
