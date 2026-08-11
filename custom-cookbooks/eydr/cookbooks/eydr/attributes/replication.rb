default["dr_replication"] = {
  production: {
    master: {
      public_hostname: "",
    },
    # MySQL Only
    initiate: {
      public_hostname: "",
    },
    slave: {
      public_hostname: "",
    },
  },
  # XtraBackup and qpress are installed from the Percona apt repo on Noble
  # (see recipes/install_xtrabackup.rb). No hardcoded download URL is needed:
  # the focal 8.0.29 tarball previously pinned here neither matches Noble nor
  # can back up a MySQL 8.4 server (XtraBackup major must equal server major).
}

# Set to true to establish replication during Chef run
default["establish_replication"] = false

# Set to true to failover to D/R environment during Chef run
default["failover"] = false
