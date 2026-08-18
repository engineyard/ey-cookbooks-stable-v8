postgresql
========

A chef recipe for managing the installed version of PostgreSQL server and client tools on EngineYard AppCloud. This recipe uses installs from the internal Engine Yard Portage tree (Gentoo). Includes support for installing PostgreSQL client tools for working with RDS PostgreSQL.

NOTE: Whenever a new version is release, this is one of the sites/services used to analyze the changes and update the recipes.

Which PostgreSQL patch version gets installed
=============================================

`server_install` decides the patch version to install on every converge, not
only on first boot. The version it picks comes from the first of these that
applies:

1. **The lock version file**, when `lock_db_version` is enabled for the
   environment. The version in that file is used exactly. If the apt repository
   no longer publishes it, the converge fails rather than installing something
   else — holding one specific version is what the lock is for.
2. **`EY_POSTGRES_VERSION`**, when set. Same exact-or-fail behaviour.
3. **The version already installed on the instance**, when the PostgreSQL
   packages are present. This is what keeps a running database where it is: a
   routine converge re-installs the same patch version and does not move it.
4. **The default version for the series** (`attributes/version.rb`), on a fresh
   instance with nothing installed yet. If that exact patch is no longer
   published, the newest patch still published in the same major series is used.

How a newer patch build reaches instances
-----------------------------------------

- **New instances** pick up the newest published patch in the series
  automatically, via case 4.
- **Existing instances stay on the patch they have**, by design — a routine
  Chef Apply must not restart and move a customer's database as a side effect
  of unrelated work. They move when either:
  - the patch they are running stops being published in the apt repository, in
    which case case 3 moves them to the newest patch still published in the same
    major series and logs a warning naming both versions; or
  - an explicit pin is set (`lock_db_version` or `EY_POSTGRES_VERSION`) to the
    desired patch, which is then honoured exactly.

  Raising the default version in `attributes/version.rb` on its own therefore
  changes only what a *fresh* install resolves to; it does not move existing
  instances.

  When a move does happen, the `apt install` that applies it runs the PostgreSQL
  package's standard post-install scripts, which restart the database service.
  The move is between patch releases of the same major series, so it needs no
  `pg_upgrade` and does not change the data directory format — but the restart
  is part of it. To hold one specific patch and never move, enable
  `lock_db_version` or set `EY_POSTGRES_VERSION`.

Every one of these decisions is written to the converge log — at info level for
the ordinary "resolved to this version, pinned by this" case, and at warn level
whenever the resolved version differs from the one requested.

dependencies
============

- ebs - manages the attachment and formatting of EBS volumes, and physical backup scheduling
- ey-lib - provides internal stack functionality
- ey-backup - establishes logical backup scheduling
- db-ssl - generates and distributes ssl keys for database connection encryption _(off by default)_

Extensions
==========

Postgres core extensions can be specified for a database by either:

- Creating /db/postgresql/extensions.json with the following format (double quotes `"` and hard brackets `[` are required):

    ```
    {
      "dbname": ["ext_name", ...],
      ....
    }
    ```
    
- Using the pg_extension custom resource directly in a cookbook:

    ```
    pg_extension 'resource block name' do
      ext_name [String, Array] # required, either a single extension name or multiple in an array
      db_name [String, Array] # required, either a single db name or multiple in an array
      schema_name String # optional, name of schema to install extension(s) to, must be present in all db specified in db_name
      version String # optional, version of extension to install, only applicable if single ext_name is given
      old_version # optional, for replacing old style non-extension contrib package
    end
    ```
    
See PostgreSQL CREATE EXTENSION docs for full explanation of schema_name, version, and old_version
