# ey-postgresql regression tests

Automated coverage for the ey-postgresql custom resources' Chef-17
compatibility, ported from `ey-cookbooks-stable-v7` (GHI-21914) to this v8
repo.

## v8 defect status (important — read before assuming parity with v7)

v8 was seeded from a v7 commit ([`6a17cf4`](https://github.com/engineyard/ey-cookbooks-stable-v7/commit/6a17cf4))
that **predates** the GHI-21914 fix landing on v7's `next-release`. That means
v8 did not just lack this test suite — its `pg_extension`, `createdb`, and
`server_configure.rb` "process extensions.json" code **still carried the
original, unfixed bugs**. This repo carries the v7 fix forward into v8
alongside the ported tests, so the suite is green on genuinely-fixed code, not
just copied onto already-working code. Confirmed empirically (not assumed):
running the pre-port v8 `pg_extension.rb` through `chef-solo` reproduced the
exact `NameError: undefined local variable or method 'ext_name'` from the
original defect.

| File | Needs a DB? | Covers |
|------|-------------|--------|
| `pg_extension_integration_test.rb` | **Yes** (live PostgreSQL) | All four fixes, asserted against real database state |
| `pg_extension_regression.sh` | No (chef-solo only) | Fast `NameError` gate for `pg_extension` (String + Array) and `createdb` |
| `version_resolution_spec.rb` | No (pure Ruby) | Which PostgreSQL patch version a converge resolves to, and why |
| `install_script_spec.rb` | No (bash + recorded apt output) | That the install script asks apt for the exact version Chef resolved |

## Version resolution, in two layers

Picking the right patch version takes both layers agreeing, so each has its own
suite:

- `version_resolution_spec.rb` covers the **Chef** layer — the pin precedence
  (lock file, `EY_POSTGRES_VERSION`, the version already installed, the default
  attribute), the newest-in-series fallback, repeat-converge stability, and the
  parsing of dpkg's own output.
- `install_script_spec.rb` covers the **shell** layer — the rendered
  `install.sh` must ask apt for exactly the version Chef resolved. It renders
  the ERB template as Chef does and runs it as real bash with a fake
  `apt-cache`/`apt` on PATH, replaying recorded `apt-cache madison` output, and
  asserts on the version string apt was actually handed.

  This layer needs its own coverage because an exact resolution in Chef is
  worthless if the script then matches it loosely: the script decides what apt
  installs. The defect it guards is a prefix match on the version, under which a
  request for `17.1` installs `17.11`.

Both run in CI on every PR touching `cookbooks/ey-postgresql/**` — see
`.github/workflows/ey-postgresql-tests.yml` (PostgreSQL 16 service container,
Chef 17.9.46 via `spec/Gemfile`).

## The four fixes under test

1. **Property access (`pg_extension`)** — `action :install` must read properties
   via `new_resource.*`. Bare `ext_name`/`db_name` raised
   `NameError: undefined local variable or method 'ext_name'` under Chef 17.
   Covered for **both** single-string and Array-typed values.
2. **SQL quoting** — `CREATE EXTENSION ... VERSION '<v>'` / `FROM '<v>'` must be
   quoted; unquoted `VERSION 1.4` was a PostgreSQL syntax error.
3. **Dynamic path** — `server_configure.rb`'s "process extensions.json" block
   must resolve the resource via `declare_resource(:ey_postgresql_pg_extension, …)`;
   the old `Chef::Resource::PostgresqlPgExtension` constant (a pre-rename name)
   raised `uninitialized constant` on every Apply that had an `extensions.json`.
4. **Property access (`createdb`)** — same bug class in the sibling `createdb`
   resource: `action :createdb_action` read `db_name`/`owner` as bare identifiers
   (and `db_name` was not even a declared property — the DB-name property is
   `name`), raising `NameError` for any customer cookbook that calls
   `createdb 'x' do … end`. Fixed to `new_resource.name` / `new_resource.owner`.

## Running locally

Prerequisites: `chef-solo` on PATH (`cd spec && bundle install`), and — for the
integration test — a reachable PostgreSQL 16 superuser `postgres`. The bundled
extensions used (`hstore`, `pg_trgm`) ship with core PostgreSQL, so no PostGIS
packages are required.

```bash
cd cookbooks/ey-postgresql/spec
bundle install

# Integration test (real DB). psql -U postgres must connect via PG* env vars:
PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres \
  bundle exec ruby pg_extension_integration_test.rb

# Fast no-DB gate:
bundle exec ./pg_extension_regression.sh   # exit 0 = pass, 1 = regression

# Version resolution (pure Ruby, no DB, no network):
bundle exec ruby version_resolution_spec.rb
bundle exec ruby install_script_spec.rb
```

Each test is self-checking: reverting any one of the four fixes turns the
corresponding assertion red. This was confirmed during this port: reverting
each fix in turn caused its corresponding assertion to fail, then re-applying
the fix made it pass again.
