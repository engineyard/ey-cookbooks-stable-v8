#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the PostgreSQL install script
# (cookbooks/ey-postgresql/templates/default/install.sh.erb).
#
# Run: ruby cookbooks/ey-postgresql/spec/install_script_spec.rb
#   or: bundle exec ruby spec/install_script_spec.rb
#        (from cookbooks/ey-postgresql/spec/, which uses the spec/Gemfile)
#
# WHY A SEPARATE, SHELL-LEVEL SUITE
#
# version_resolution_spec.rb covers the Chef layer, which resolves a package
# version exactly. That resolution is worthless if the script it hands the
# version to then matches it loosely: the script, not Chef, decides which
# package apt actually installs. The two layers have to agree, and only running
# the script can show that they do.
#
# The specific defect this guards: get_full_pkg_version used to expand
# "${package_version}*" into an apt-cache query, so a request for "16.4" also
# matched "16.40", and a request for "17.1" installed "17.11". Measured against
# the real archive, series 15 and 17 both publish a low single-digit patch and a
# double-digit sibling, so this is reachable, not theoretical.
#
# METHOD
#
# The ERB template is rendered exactly as Chef renders it, then run as real bash
# with a fake apt-cache / apt / systemctl on PATH. The fake apt-cache replays
# recorded apt-cache madison output; the fake apt records the arguments it was
# called with, so the assertions are about the package version apt was actually
# asked to install -- the thing that determines what ends up on the instance.
# Nothing here touches the host's package manager.

require "minitest/autorun"
require "erb"
require "tmpdir"
require "fileutils"

TEMPLATE_FILE = File.expand_path("../templates/default/install.sh.erb", __dir__)

# Recorded apt-cache madison output. Real shape: leading whitespace, three
# pipe-separated fields, one row per published version, newest first, and the
# same version repeated once per suite/component it is published in.
#
# Series 17 is the measured case that makes the old glob wrong: 17.1 exists in
# the archive, and so does 17.11.
MADISON_PG17 = <<~OUT
  postgresql-17 | 17.11-1.pgdg24.04+2 | https://apt-archive.postgresql.org/pub/repos/apt noble-pgdg-archive/main amd64 Packages
  postgresql-17 | 17.10-1.pgdg24.04+1 | https://apt-archive.postgresql.org/pub/repos/apt noble-pgdg-archive/main amd64 Packages
  postgresql-17 |  17.9-1.pgdg24.04+1 | https://apt-archive.postgresql.org/pub/repos/apt noble-pgdg-archive/main amd64 Packages
  postgresql-17 |  17.2-1.pgdg24.04+1 | https://apt-archive.postgresql.org/pub/repos/apt noble-pgdg-archive/main amd64 Packages
  postgresql-17 |  17.1-1.pgdg24.04+1 | https://apt-archive.postgresql.org/pub/repos/apt noble-pgdg-archive/main amd64 Packages
  postgresql-17 |  17.1-1.pgdg24.04+1 | https://apt-archive.postgresql.org/pub/repos/apt noble-pgdg-archive/main i386 Packages
OUT

# Series 16, the version this stack ships. 16.4 has no double-digit sibling
# today, which is why the defect was latent rather than live.
MADISON_PG16 = <<~OUT
  postgresql-16 | 16.15-1.pgdg24.04+1 | https://apt-archive.postgresql.org/pub/repos/apt noble-pgdg-archive/main amd64 Packages
  postgresql-16 | 16.10-1.pgdg24.04+1 | https://apt-archive.postgresql.org/pub/repos/apt noble-pgdg-archive/main amd64 Packages
  postgresql-16 |  16.4-1.pgdg24.04+1 | https://apt-archive.postgresql.org/pub/repos/apt noble-pgdg-archive/main amd64 Packages
OUT

# A package carrying a dpkg epoch. The epoch is ordering metadata, not part of
# the upstream version, so it must not defeat the comparison -- but it must be
# preserved in the string handed to apt, which needs the full version verbatim.
MADISON_EPOCH = <<~OUT
  postgresql-16 | 1:16.4-1.pgdg24.04+1 | https://apt-archive.postgresql.org/pub/repos/apt noble-pgdg-archive/main amd64 Packages
OUT

# Renders install.sh.erb the way the Chef template resource does: the template
# reads @postgres_version and @package_version from the variables it is given.
class InstallScriptRenderer
  def initialize(postgres_version:, package_version:)
    @postgres_version = postgres_version
    @package_version = package_version
  end

  def render
    ERB.new(File.read(TEMPLATE_FILE)).result(binding)
  end
end

class InstallScriptTest < Minitest::Test
  # Run the rendered script in a sandbox whose PATH holds fakes for every
  # command it shells out to. Returns [stdout+stderr, exit status, apt argv].
  #
  # The fake apt-cache replays `madison` output and ignores anything else; the
  # fake apt appends its arguments to a file; the fake systemctl does nothing.
  def run_install_script(postgres_version:, package_version:, madison:)
    script = InstallScriptRenderer.new(postgres_version: postgres_version,
                                       package_version: package_version).render

    Dir.mktmpdir do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      madison_file = File.join(dir, "madison.txt")
      apt_log = File.join(dir, "apt-args.txt")
      File.write(madison_file, madison)

      write_exec(File.join(bin, "apt-cache"), <<~SH)
        #!/bin/bash
        if [[ "$1" == "madison" ]]; then cat #{madison_file}; fi
      SH
      write_exec(File.join(bin, "apt"), <<~SH)
        #!/bin/bash
        echo "$@" >> #{apt_log}
      SH
      # `systemctl status postgresql` is expected to fail on a host with no
      # postgresql unit; the script only greps its output, so exit 0 quietly.
      write_exec(File.join(bin, "systemctl"), "#!/bin/bash\nexit 0\n")

      script_file = File.join(dir, "install.sh")
      File.write(script_file, script)
      FileUtils.chmod(0o755, script_file)

      output = `PATH=#{bin}:$PATH #{script_file} 2>&1`
      status = $?.exitstatus
      apt_argv = File.exist?(apt_log) ? File.read(apt_log).lines.map(&:strip) : []
      [output, status, apt_argv]
    end
  end

  def write_exec(path, body)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end

  # The version apt was asked to install for a given package, e.g.
  # "17.1-1.pgdg24.04+1" from "install -y ... postgresql-17=17.1-1.pgdg24.04+1".
  def installed_version_for(apt_argv, package)
    line = apt_argv.find { |l| l.include?("#{package}=") }
    return nil unless line
    line[/#{Regexp.escape(package)}=(\S+)/, 1]
  end

  # -------------------------------------------------------------------------
  # THE DEFECT: an exact version must not be satisfied by a longer-digit
  # sibling. This is the shell-layer twin of the Chef layer's "16.4 must not
  # match 16.40" rule, and it is the layer that decides what apt installs.
  # -------------------------------------------------------------------------

  def test_exact_version_is_not_satisfied_by_a_longer_digit_sibling
    _, status, apt_argv = run_install_script(postgres_version: "17",
                                             package_version: "17.1",
                                             madison: MADISON_PG17)
    assert_equal 0, status, "the script must succeed when the exact version is published"
    installed = installed_version_for(apt_argv, "postgresql-17")
    assert_equal "17.1-1.pgdg24.04+1", installed,
                 "pinning 17.1 must install 17.1, not the 17.11 a prefix glob would match"
    refute_match(/\A17\.11/, installed.to_s,
                 "17.11 is a different version from 17.1 and must never satisfy it")
  end

  def test_every_package_in_the_run_gets_the_exact_version
    # The script installs three packages; a loose match on any one of them puts
    # a mismatched client or server-dev alongside the server.
    _, status, apt_argv = run_install_script(postgres_version: "17",
                                             package_version: "17.1",
                                             madison: MADISON_PG17)
    assert_equal 0, status
    %w[postgresql-client-17 postgresql-17 postgresql-server-dev-17].each do |package|
      assert_equal "17.1-1.pgdg24.04+1", installed_version_for(apt_argv, package),
                   "#{package} must be pinned to the exact requested upstream version"
    end
  end

  def test_a_double_digit_request_still_resolves_to_itself
    # The converse: asking for 17.11 must get 17.11, so the exact match did not
    # merely become "shortest wins".
    _, status, apt_argv = run_install_script(postgres_version: "17",
                                             package_version: "17.11",
                                             madison: MADISON_PG17)
    assert_equal 0, status
    assert_equal "17.11-1.pgdg24.04+2", installed_version_for(apt_argv, "postgresql-17")
  end

  # -------------------------------------------------------------------------
  # FAIL LOUDLY when the exact version is not published. The script must not
  # install a near-miss, and must not proceed as if it had installed anything.
  # -------------------------------------------------------------------------

  def test_absent_version_fails_and_installs_nothing
    output, status, apt_argv = run_install_script(postgres_version: "17",
                                                  package_version: "17.3",
                                                  madison: MADISON_PG17)
    refute_equal 0, status, "an unavailable exact version must fail the run"
    assert_match(/17\.3 of postgresql-client-17 not found/, output)
    assert_empty apt_argv, "nothing may be installed when the exact version is absent"
  end

  def test_a_version_that_is_only_a_prefix_of_a_published_one_fails
    # "17.1" is published, so a request for "17" must NOT be satisfied by it --
    # under the old glob, "17*" matched every version in the series and silently
    # installed whichever apt-cache listed first.
    output, status, apt_argv = run_install_script(postgres_version: "17",
                                                  package_version: "17",
                                                  madison: MADISON_PG17)
    refute_equal 0, status, "a bare series number is not a published version and must fail"
    assert_match(/not found/, output)
    assert_empty apt_argv
  end

  # -------------------------------------------------------------------------
  # The published version string is passed to apt verbatim.
  # -------------------------------------------------------------------------

  def test_the_full_debian_version_is_passed_to_apt_verbatim
    # apt needs the complete version, revision and all; handing it the bare
    # upstream version installs nothing.
    _, status, apt_argv = run_install_script(postgres_version: "16",
                                             package_version: "16.4",
                                             madison: MADISON_PG16)
    assert_equal 0, status
    assert_equal "16.4-1.pgdg24.04+1", installed_version_for(apt_argv, "postgresql-16")
  end

  def test_an_epoch_does_not_defeat_the_match_and_is_preserved_for_apt
    # The epoch is stripped for comparison (it is not part of the upstream
    # version) but kept in the string apt is given, which needs it to resolve
    # the package at all.
    _, status, apt_argv = run_install_script(postgres_version: "16",
                                             package_version: "16.4",
                                             madison: MADISON_EPOCH)
    assert_equal 0, status, "an epoch-carrying package must still match its upstream version"
    assert_equal "1:16.4-1.pgdg24.04+1", installed_version_for(apt_argv, "postgresql-16"),
                 "the epoch must survive into the string handed to apt"
  end

  def test_newest_matching_row_is_used_when_a_version_is_published_more_than_once
    # madison lists the same version once per suite/component. All rows carry
    # the same version string, so any of them is correct -- but exactly one
    # install must be issued per package, not one per duplicated row.
    _, status, apt_argv = run_install_script(postgres_version: "17",
                                             package_version: "17.1",
                                             madison: MADISON_PG17)
    assert_equal 0, status
    installs = apt_argv.count { |l| l.include?("postgresql-17=") }
    assert_equal 1, installs, "duplicated madison rows must not produce duplicate installs"
  end

  # -------------------------------------------------------------------------
  # Rendering: the version Chef resolved is the version the script asks for.
  # -------------------------------------------------------------------------

  def test_rendered_script_carries_the_resolved_version_and_series
    script = InstallScriptRenderer.new(postgres_version: "16", package_version: "16.4").render
    assert_match(/get_full_pkg_version "postgresql-16" "16\.4"/, script)
    assert_match(/get_full_pkg_version "postgresql-client-16" "16\.4"/, script)
    assert_match(/get_full_pkg_version "postgresql-server-dev-16" "16\.4"/, script)
  end

  def test_rendered_script_does_not_glob_the_version
    # A structural guard on top of the behavioural ones: reintroducing a
    # trailing "*" on the version is the exact shape of the original defect.
    # Comment lines are excluded -- the script documents the old glob by name.
    script = InstallScriptRenderer.new(postgres_version: "16", package_version: "16.4").render
    code = script.lines.reject { |l| l.strip.start_with?("#") }.join
    refute_match(/\$\{package_version\}\*/, code,
                 "the version must not be glob-expanded into the apt query")
  end
end
