#!/bin/bash

set -e

usage="
Usage: ${0} [-h] <dbname>

-h          This help listing
<dbname>    The db name with connections to kill.  Typically the same as the application name.
"

if [[ -z "${1}" ||"${1}" = "-h" ]]
then
    echo "${usage}"
    exit
fi

app_name=$1

# Warn & prompt before continuing
echo -e -n "WARNING: Running this script will kill all connections to the ${app_name} database!\n\nContinue? (y/n) "
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

# kill any active connections on ${app_name} db
#
# Uses pg_stat_activity.pid unconditionally, with no pre-9.2 fallback.
# eselect is a Gentoo tool with no v8 (Ubuntu 24.04) provider, so
# `eselect postgresql show` always resolved to an empty string here, which
# silently selected the 'procpid' branch -- a column removed in PostgreSQL
# 9.2 ("column p.procpid does not exist"). That made the SELECT fail, the
# kill loop iterate over nothing, and any subsequent drop hang or fail on
# an in-use database.
# On the v8 stack this is safe with no version guard: AWSM's
# STACK_LABELS_STABLE_V8_RESTRICTIONS (lib/awsm/stack_restrictions.rb)
# DENY-lists every PostgreSQL below 16, so PostgreSQL 16 -- which has pid,
# not procpid -- is the only permitted engine on v8 and a pre-9.2 branch
# would be dead code.
echo "Killing active connections on ${app_name}"
query="
SELECT pid
FROM pg_stat_activity
WHERE datname='${app_name}';"
for pid in $(psql -U postgres -t -c"$query" postgres);
do
    kill $pid
done
