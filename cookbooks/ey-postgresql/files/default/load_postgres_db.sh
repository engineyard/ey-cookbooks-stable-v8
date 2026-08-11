#!/bin/bash

set -o errexit

usage="
Usage: ${0} [-h] <dumpfile> <dbname> [dbuser]

-h          This help listing
<dumpfile>  The dump file path.
<dbname>    The db name.  Typically the same as the application name.
[dbuser]    An optional db user to use for setting ownership of the db.
            If this is supplied the user must already exist on the db server.
            Default: deploy
"

if [[ -z "${1}" || -z "${2}" || "${1}" = "-h" ]]
then
    echo "${usage}"
    exit
fi

dump_file=$1
app_name=$2
[[ -z "${3}" ]] && db_user='deploy' || db_user=${3}

if [ ! -f "${dump_file}" ]
then
    echo "${dump_file} does not exist."
    exit 1
fi

function check_continue() {
    prompt_message=${1}
    echo -e -n "${prompt_message}\n\nContinue? (y/n) "
    while read;
    do
        if [ "${REPLY}" = 'y' ]
        then
            break
        fi

        if [ "${REPLY}" = 'n' ]
        then
            exit 0
        fi

        echo -e -n "Please, enter 'y' for yes or 'n' for no.\n\nContinue? (y/n)"
    done
}

set +o errexit
psql -U postgres -t -c"SELECT rolname FROM pg_roles WHERE rolname = '${db_user}';" | grep -q "${db_user}" > /dev/null 2>&1
res=$?
set -o errexit

if [ "$res" != "0" ]
then
    check_continue "\n${db_user} database user not found.  We'll need to create it to continue."

    while true;
    do
        read -p "Password for new user (required): " new_pass

        if [ -z "${new_pass}" ]
        then
            echo "Non-zero length password required."
            continue
        fi

        read -p "One more time for posterity: " repeat
        if [ "${repeat}" != "${new_pass}" ]
        then
            echo "Passwords do not match!"
            continue
        fi
        break
    done
    psql -U postgres -c"CREATE USER ${db_user} WITH ENCRYPTED PASSWORD '${new_pass}';"
fi

set +o errexit
psql -U postgres -t -c"SELECT datname FROM pg_database WHERE datname = '${app_name}';" | grep -q "${app_name}" > /dev/null 2>&1
res=$?
set -o errexit
if [ "$res" = "0" ]
then
    # Warn & prompt before continuing
    check_continue "\nWARNING: ${app_name} database found.  To continue we will drop and recreate the ${app_name} database!"

    # kill any active connections on ${app_name} db
    #
    # Uses pg_stat_activity.pid unconditionally, with no pre-9.2 fallback.
    # eselect is a Gentoo tool with no v8 (Ubuntu 24.04) provider, so
    # `eselect postgresql show` always resolved to an empty string here,
    # which silently selected the 'procpid' branch -- a column removed in
    # PostgreSQL 9.2 ("column p.procpid does not exist"). That made the
    # SELECT fail, the kill loop iterate over nothing, and the subsequent
    # dropdb hang or fail on an in-use database.
    # On the v8 stack this is safe with no version guard: AWSM's
    # STACK_LABELS_STABLE_V8_RESTRICTIONS (lib/awsm/stack_restrictions.rb)
    # DENY-lists every PostgreSQL below 16, so PostgreSQL 16 -- which has
    # pid, not procpid -- is the only permitted engine on v8 and a
    # pre-9.2 branch would be dead code.
    echo "Killing active connections on ${app_name} before dropping it."
    query="
    SELECT pid
    FROM pg_stat_activity
    WHERE datname='${app_name}';"
    for pid in $(psql -U postgres -t -c"$query" postgres);
    do
        kill $pid
    done

    # start fresh and make the app user the owner of the public schema
    echo "Dropping the ${app_name} database."
    dropdb -U postgres ${app_name}
else
    check_continue "\n${app_name} database not found. To continue we'll need to create it."
fi

echo -e "\nCreating the ${app_name} dataabase."
createdb -U postgres -O ${db_user} ${app_name}

# is this a custom dump?
set +e
pg_restore -l ${dump_file} > /dev/null 2>&1
res=$?
set -e

# load the dump
echo -e "\nRestoring ${dump_file} to the ${app_name} database."
if [ "${res}" = "0" ]
then
    pg_restore -d ${app_name} --no-owner --no-privileges -U postgres ${dump_file}
else
    psql -U postgres -f ${dump_file} ${app_name}
fi

function gen_run_queries() {
    # Capture the generated DDL before piping it into psql. Running the two
    # psql invocations as a single pipeline masks a failure in the first
    # (generating) psql: a bash pipeline's exit status is that of its LAST
    # command, so a catalog error in the generator (e.g. a column removed in a
    # newer PostgreSQL major) is silently swallowed while the pipeline returns
    # the second psql's 0. Splitting the command substitution onto its own line
    # lets errexit abort on such a failure instead. An empty result (no matching
    # objects) is a valid no-op and leaves errexit undisturbed.
    # ON_ERROR_STOP=1 on the consumer keeps a statement-level error (e.g. an
    # unresolvable identifier) from being swallowed too: without it this psql
    # is the pipeline's last command, so it alone determines the function's
    # return status and a failed ALTER inside it would otherwise report 0.
    local generated_sql
    generated_sql=$(psql -U postgres -t -c "${gen_query}" ${app_name})
    echo "${generated_sql}" | psql -v ON_ERROR_STOP=1 -U postgres ${app_name}
}

# fix ownership of all tables, views, and sequences to the app user
echo -e "\nSetting ownership of all relations from ${dump_file} to ${db_user}."
gen_query="
SELECT 'ALTER ' || CASE t.relkind
                    WHEN 'r' THEN 'TABLE '
                    WHEN 'S' THEN 'SEQUENCE '
                    WHEN 'v' THEN 'VIEW '
                    WHEN 'm' THEN 'MATERIALIZED VIEW '
                    END || quote_ident(n.nspname) || '.' || quote_ident(t.relname) || ' OWNER TO ${db_user};'
FROM pg_class t, pg_namespace n
WHERE t.relnamespace=n.oid
    AND n.nspname != 'information_schema' AND n.nspname NOT LIKE E'pg\_%'
    AND (t.relkind IN ('r', 'v', 'm') OR
         -- this is a filter for sequences not owned by tables
         (t.relkind = 'S'
            AND t.oid NOT IN (SELECT d.objid
                            FROM pg_depend d, pg_class t
                            WHERE d.refobjid = t.oid
                              AND t.relkind = 'r')))
ORDER BY relkind, relname;"
gen_run_queries

# fix the ownership of all the schemas to be the app user
echo -e "\nSetting ownership of all schemas from ${dump_file} to ${db_user}."
gen_query="
SELECT 'ALTER SCHEMA ' || quote_ident(nspname) || ' OWNER TO ${db_user};'
FROM pg_namespace
WHERE nspname != 'information_schema' AND nspname NOT LIKE 'pg_%';"
gen_run_queries

# fix the ownership of all non-system functions and aggregates to the app user
#
# Uses pg_proc.prokind (char: 'f' function, 'a' aggregate, 'p' procedure,
# 'w' window) unconditionally, with no pre-11 fallback. prokind replaced the
# boolean pg_proc.proisagg column, which was removed in PostgreSQL 11; the old
# proisagg query errors ("column p.proisagg does not exist") on any PG >= 11.
# On the v8 stack this is safe with no version guard: AWSM's
# STACK_LABELS_STABLE_V8_RESTRICTIONS (lib/awsm/stack_restrictions.rb) DENY-lists
# every PostgreSQL below 16 (postgres9_5/9_6/10/11/12/13/14), so PostgreSQL 16 is
# the only permitted engine on v8 and a pre-11 branch would be dead code.
# Emitting the correct object keyword per prokind also fixes the ALTER: a
# procedure cannot be altered with ALTER FUNCTION (errors "is not a function"),
# so it needs ALTER PROCEDURE. (ALTER FUNCTION does happen to work on an
# aggregate on PG16, but ALTER AGGREGATE is the correct, explicit form.)
# pg_get_function_identity_arguments() renders the argument list, but for a
# 0-arg AGGREGATE it returns an empty string, and ALTER AGGREGATE requires the
# explicit "(*)" form in that case -- an empty arg list is a syntax error
# ("ALTER AGGREGATE foo() OWNER TO ...;"). The CASE below supplies '*' only
# for that one case; 0-arg functions/procedures correctly use "()".
# quote_ident() on the schema/name guards against quoted mixed-case
# identifiers, which the unquoted form silently down-folds and then can't
# resolve (e.g. "myMixedFn" -> mymixedfn, "does not exist").
# The pg_depend anti-join excludes objects owned by an extension (e.g.
# hstore, pg_trgm): those are not user-defined and this restore path had
# never previously reached them, since the old proisagg query errored before
# getting this far on any PG >= 11.
echo -e "\nSetting ownership of all user-defined functions and aggregates from ${dump_file} to ${db_user}."
gen_query="
SELECT 'ALTER ' || CASE p.prokind
                    WHEN 'a' THEN 'AGGREGATE'
                    WHEN 'p' THEN 'PROCEDURE'
                    ELSE 'FUNCTION'
                   END || ' ' || quote_ident(n.nspname) || '.' || quote_ident(p.proname) || '('
    || CASE WHEN p.prokind = 'a' AND p.pronargs = 0
            THEN '*'
            ELSE pg_get_function_identity_arguments(p.oid)
       END
    || ') OWNER TO ${db_user};'
FROM pg_proc p, pg_namespace n
WHERE p.pronamespace = n.oid
    AND n.nspname != 'information_schema' AND n.nspname NOT LIKE E'pg\_%'
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e');"
gen_run_queries

echo -e "\nSetting ownership of all user-defined types from ${dump_file} to ${db_user}."
gen_query="
SELECT 'ALTER TYPE ' || quote_ident(n.nspname) || '.' || quote_ident(typname) || ' OWNER TO ${db_user};'
FROM pg_type t, pg_namespace n
WHERE n.nspname != 'information_schema' AND n.nspname NOT LIKE 'pg_%'
    AND t.typnamespace = n.oid
    AND t.typname NOT LIKE '\_%'
    AND (t.typrelid = 0 OR (SELECT TRUE
                            FROM pg_class c
                            WHERE c.oid = t.typrelid AND c.relkind = 'c'));"
gen_run_queries
