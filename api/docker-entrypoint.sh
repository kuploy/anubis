#!/bin/sh

set -ex

# ---------------------------------------------------------------------------
# DATABASE_URI, composed from parts when the platform can only supply parts.
#
# Anubis defaults to mysql+pymysql://anubis:anubis@$DB_HOST/anubis
# (anubis/env.py). kuploy's managed MariaDB cannot be told to use those
# credentials: it derives the database name and user from the component name
# and generates the password, so a kuploy deploy gets something like
# anubis_db/anubis_db/<random hex>.
#
# DATABASE_URI is the documented override and would solve it, except that a
# kuploy stack spec cannot BUILD the string: each env entry is one-of
# generate | fromInput | value | fromComponent, so a literal scheme cannot be
# concatenated with connection fields, and the mariadb connectionString field
# emits `mysql://` rather than the `mysql+pymysql://` SQLAlchemy driver scheme.
# The spec can pass the parts, so we assemble them here.
#
# Only when DATABASE_URI is unset, so docker-compose, the upstream Helm chart
# (k8s/chart sets DATABASE_URI directly) and anyone passing a full URI keep
# theirs untouched. DB_PASSWORD may legitimately be empty; DB_USER and DB_NAME
# are what tell us the parts were supplied at all.
#
# NOTE ON ENCODING: the parts are interpolated raw. kuploy generates its
# password as hex (randomBytes(12).toString("hex")), which is URI-safe, so this
# is correct for the platform it exists for. A password containing @ : / or ?
# would need percent-encoding and this would build a broken URI rather than
# fail loudly — pass a complete DATABASE_URI in that case.
# ---------------------------------------------------------------------------
if [ -z "${DATABASE_URI}" ] && [ -n "${DB_USER}" ] && [ -n "${DB_NAME}" ]; then
    DATABASE_URI="mysql+pymysql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT:-3306}/${DB_NAME}"
    export DATABASE_URI
    echo "composed DATABASE_URI from DB_* parts for ${DB_USER}@${DB_HOST}/${DB_NAME}"
fi

# ---------------------------------------------------------------------------
# Wait for the database to be USABLE, not merely listening.
#
# `mysqladmin ping` exits 0 on access denied. Not "tolerates" — always: this
# loop passes no credentials, so it gets
#
#   Access denied for user 'root'@'...' (using password: NO)   exit 0
#
# every single time. Its only signal is that something completed a TCP
# handshake. Measured on MariaDB 11: wrong credentials, no credentials and
# correct credentials all exit 0; only the third prints "mysqld is alive".
#
# That was survivable when the next step was gunicorn, which retries its
# connections. It is not survivable now that `alembic upgrade head` runs here
# under `set -e`, because MariaDB accepts connections BEFORE mariadb-install-db
# has created the user and database. On Longhorn that window was measured at
# over 18 minutes, pod 1/1 Ready throughout. The container would ping, migrate,
# die on 1045/1049, and crash-loop until init finished — self-healing, but the
# log would carry an alembic error while the real state was "the database is
# not ready and the loop could not tell".
#
# So when the credentials are known, wait on a query that needs all three
# facts alembic needs: server up, credentials valid, database present. The
# bare ping stays as the fallback for compose and the chart, which pass
# DATABASE_URI rather than parts, so their behaviour is unchanged.
# ---------------------------------------------------------------------------
echo 'Waiting for db...'
if [ -n "${DB_USER}" ] && [ -n "${DB_NAME}" ]; then
    # --skip-ssl: this image ships the MariaDB 11.8 client, which REQUIRES TLS
    # by default and fails with "SSL is required, but the server does not
    # support it" against a server that does not offer it (measured against
    # mariadb:10.6). mariadb:11 — kuploy's default — does offer TLS, so this
    # flag changes nothing there; without it the loop would spin forever on an
    # older server, which is worse than the bug it exists to fix. The app's own
    # connection (pymysql) is not TLS either, so this probe is no weaker than
    # the traffic that follows it.
    until mysql --skip-ssl -h "${DB_HOST}" -P "${DB_PORT:-3306}" \
                -u "${DB_USER}" "-p${DB_PASSWORD}" \
                -e 'select 1' "${DB_NAME}" >/dev/null 2>&1; do
        echo "  waiting for ${DB_USER}@${DB_HOST}/${DB_NAME} to accept a query"
        sleep 2
    done
else
    until mysqladmin ping -h "${DB_HOST}" -P "${DB_PORT:-3306}"; do
        sleep 1
    done
fi
echo 'db ready'

echo 'Waiting a second'
sleep 1

if [ "${DEBUG}" = "1" ]; then
    set +e
    while true; do
        python3 dev.py
        sleep 1
        echo 'restarting'
    done
fi

# ---------------------------------------------------------------------------
# Schema. Nothing in this container used to touch it.
#
# docker-entrypoint.sh waited for the database and exec'd gunicorn. There are
# 76 revisions in migrations/versions and the only `alembic upgrade head` in
# this repo is in Makefiles a human runs from OUTSIDE the container. Upstream
# migrates by hand; a platform deploy has no hand. The API came up, reported
# 1/1 Ready, and had no schema.
#
# The chart's MIGRATE flag is not this mechanism: it is read only by dev.py,
# only under MINDEBUG=1, and calls db.create_all() rather than alembic — and
# MINDEBUG=1 is exactly what switches env.py onto sqlite, so the only path
# that reached create_all() could not see the real database.
#
# kuploy-db-bootstrap.py decides between two paths and says which it took.
# The header of that file has the measurements; the short version is that
# the historical chain CANNOT be replayed from an empty database on either
# MariaDB 10.6 or 11.8, so a fresh database gets the schema from the models
# and an alembic stamp, and an existing one gets the normal upgrade.
#
#   exit 10 -> schema already present   -> alembic upgrade head
#   exit 11 -> was empty, create_all'd  -> alembic stamp head
#
# Any other exit is a real failure and `set -e` stops the container, which is
# deliberate: a crash loop carrying the actual error is diagnosable, an API
# answering 500 to everything is not.
#
# SKIP_MIGRATIONS=1 is the escape hatch for a second replica or a deploy that
# handles the schema out of band. Alembic does not coordinate concurrent runs.
# ---------------------------------------------------------------------------
if [ "${SKIP_MIGRATIONS}" = "1" ]; then
    echo 'skipping schema step (SKIP_MIGRATIONS=1)'
else
    set +e
    python3 kuploy-db-bootstrap.py
    bootstrap_rc=$?
    set -e
    case "${bootstrap_rc}" in
        10) echo 'schema present: alembic upgrade head'; alembic upgrade head ;;
        11) echo 'fresh database: alembic stamp head';   alembic stamp head ;;
        *)  echo "bootstrap failed (rc=${bootstrap_rc})"; exit "${bootstrap_rc}" ;;
    esac
fi

echo 'Starting api'
exec gunicorn ${GUNICORN_OPTIONS} \
    -w ${WORKERS:-4} \
    -b 0.0.0.0:5000 \
    "anubis.app:${CREATE_APP_FUNCTION:-create_app}()"
