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

echo 'Waiting for db...'
until mysqladmin ping -h "${DB_HOST}" -P "${DB_PORT:-3306}"; do
    sleep 1
done
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
# Migrations. Nothing in this container used to run them.
#
# There are 76 revisions in migrations/versions and the only `alembic upgrade
# head` in the repo is in Makefiles a human runs from OUTSIDE the container
# (Makefile via `docker compose exec`, api/Makefile against a venv). Upstream
# expects an operator to migrate by hand, which works for upstream and does not
# work for a one-click platform deploy: the API came up, answered 1/1 Ready,
# and had no schema.
#
# The chart's MIGRATE flag is not this. It is read only by dev.py, only under
# MINDEBUG=1, and calls db.create_all() rather than alembic — which would build
# tables from the current models and leave alembic_version unset, so the 76
# revisions could never be applied afterwards. MINDEBUG=1 is also exactly what
# switches env.py onto sqlite, so the only path that reached create_all() was
# the path that could not see the real database.
#
# Placed after the DEBUG branch (which loops forever and never falls through)
# so `make debug` and dev.py behave exactly as before.
#
# migrations/env.py builds the URL from the Flask app config, so it reads the
# DATABASE_URI composed above — one variable, both consumers, no second place
# for the credentials to disagree.
#
# `set -e` means a failed migration stops the container instead of serving an
# app with no schema. That is deliberate: a crash loop with alembic's error in
# the log is diagnosable, an API answering 500 to everything is not.
#
# SKIP_MIGRATIONS=1 is the escape hatch for a second replica or a deploy that
# migrates out of band. Alembic does not coordinate concurrent runs, so if this
# component is ever scaled past one replica the extras need it set.
# ---------------------------------------------------------------------------
if [ "${SKIP_MIGRATIONS}" = "1" ]; then
    echo 'skipping migrations (SKIP_MIGRATIONS=1)'
else
    echo 'running migrations'
    alembic upgrade head
fi

echo 'Starting api'
exec gunicorn ${GUNICORN_OPTIONS} \
    -w ${WORKERS:-4} \
    -b 0.0.0.0:5000 \
    "anubis.app:${CREATE_APP_FUNCTION:-create_app}()"
