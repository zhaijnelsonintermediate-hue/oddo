#!/usr/bin/env bash
#
# Container entrypoint for Odoo on Railway.
#
# Railway injects the database connection as DATABASE_URL (or the PG* family
# when the Postgres service is linked variable-by-variable) and the public port
# as PORT. Odoo reads neither, so this script translates the environment into
# an odoo.conf, initialises the database on first boot, and then hands over to
# the server.

set -euo pipefail

ODOO_RC="${ODOO_RC:-/etc/odoo/odoo.conf}"
DATA_DIR="${ODOO_DATA_DIR:-/var/lib/odoo}"
ODOO_SRC="${ODOO_SRC:-/opt/odoo}"

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Resolve the database connection
# ---------------------------------------------------------------------------
if [ -n "${DATABASE_URL:-}" ]; then
    log "reading database connection from DATABASE_URL"
    # Parsing in Python rather than with a regex: passwords are percent-encoded
    # and routinely contain characters that break naive shell splitting.
    eval "$(
        python3 - <<'PY'
import os
import shlex
from urllib.parse import unquote, urlparse

url = urlparse(os.environ["DATABASE_URL"])
resolved = {
    "DB_HOST": url.hostname or "",
    "DB_PORT": str(url.port or 5432),
    "DB_USER": unquote(url.username or ""),
    "DB_PASSWORD": unquote(url.password or ""),
    "DB_NAME": (url.path or "/").lstrip("/"),
}
for key, value in resolved.items():
    print(f"{key}={shlex.quote(value)}")
PY
    )"
else
    log "reading database connection from PG* variables"
    DB_HOST="${PGHOST:-}"
    DB_PORT="${PGPORT:-5432}"
    DB_USER="${PGUSER:-}"
    DB_PASSWORD="${PGPASSWORD:-}"
    DB_NAME="${PGDATABASE:-}"
fi

[ -n "${DB_HOST}" ] || die "no database host — link a Postgres service so DATABASE_URL or PGHOST is set"
[ -n "${DB_NAME}" ] || die "no database name — DATABASE_URL must include a path, or set PGDATABASE"

# ---------------------------------------------------------------------------
# 2. Render the configuration file
# ---------------------------------------------------------------------------
HTTP_PORT="${PORT:-8069}"

# workers must stay at 0. In prefork mode Odoo serves websockets from a second
# gevent port, and Railway exposes exactly one port per service — the chatter
# and activity notifications in CRM would silently stop working. Threaded mode
# handles the websocket upgrade in-process (odoo/service/server.py:141).
WORKERS="${ODOO_WORKERS:-0}"

ADDONS_PATH="${ODOO_SRC}/odoo/addons,${ODOO_SRC}/addons"
# Odoo refuses to start when addons_path names a directory that does not exist,
# so create it rather than trusting it to be there — a bind mount or a stray
# delete would otherwise drop custom modules off the path silently.
mkdir -p "${ODOO_SRC}/custom-addons" 2>/dev/null || true
if [ -d "${ODOO_SRC}/custom-addons" ]; then
    ADDONS_PATH="${ODOO_SRC}/custom-addons,${ADDONS_PATH}"
fi

# The master password guards the database manager. Falling back to a value that
# is random per container is deliberate: a well-known default would be worse
# than one nobody can use.
ADMIN_PASSWD="${ODOO_MASTER_PASSWORD:-$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')}"

# Only expose the database manager if it was asked for explicitly.
LIST_DB="${ODOO_LIST_DB:-False}"

mkdir -p "$(dirname "${ODOO_RC}")"
cat > "${ODOO_RC}" <<EOF
[options]
admin_passwd = ${ADMIN_PASSWD}

db_host = ${DB_HOST}
db_port = ${DB_PORT}
db_user = ${DB_USER}
db_password = ${DB_PASSWORD}
db_name = ${DB_NAME}
db_sslmode = ${ODOO_DB_SSLMODE:-prefer}
db_maxconn = ${ODOO_DB_MAXCONN:-32}
dbfilter = ^${DB_NAME}\$
list_db = ${LIST_DB}

addons_path = ${ADDONS_PATH}
data_dir = ${DATA_DIR}

http_interface = 0.0.0.0
http_port = ${HTTP_PORT}
proxy_mode = True

workers = ${WORKERS}
max_cron_threads = ${ODOO_MAX_CRON_THREADS:-2}
limit_time_cpu = ${ODOO_LIMIT_TIME_CPU:-300}
limit_time_real = ${ODOO_LIMIT_TIME_REAL:-600}

log_level = ${ODOO_LOG_LEVEL:-info}
EOF
chmod 600 "${ODOO_RC}"
chown odoo:odoo "${ODOO_RC}"

# Railway attaches volumes owned by root; the server runs as odoo.
mkdir -p "${DATA_DIR}"
chown odoo:odoo "${DATA_DIR}"

log "database ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}, http port ${HTTP_PORT}, workers ${WORKERS}"

# ---------------------------------------------------------------------------
# 3. Wait for Postgres
# ---------------------------------------------------------------------------
log "waiting for postgres"
for attempt in $(seq 1 60); do
    if pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -q; then
        log "postgres is accepting connections"
        break
    fi
    [ "${attempt}" -lt 60 ] || die "postgres unreachable after 60 attempts"
    sleep 2
done

# ---------------------------------------------------------------------------
# 4. Initialise the database on first boot
# ---------------------------------------------------------------------------
# ir_module_module is created by the `base` module, so its presence is the
# cheapest reliable marker that this database has already been through an
# Odoo install.
export PGPASSWORD="${DB_PASSWORD}"
already_installed="$(
    psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
         -tAc "SELECT to_regclass('public.ir_module_module') IS NOT NULL"
)"

if [ "${already_installed}" != "t" ]; then
    INIT_MODULES="${ODOO_INIT_MODULES:-crm}"
    log "empty database — installing: ${INIT_MODULES}"

    init_args=(-c "${ODOO_RC}" -d "${DB_NAME}" -i "${INIT_MODULES}" --stop-after-init --no-http)
    if [ "${ODOO_WITH_DEMO:-0}" = "1" ]; then
        log "demo data enabled"
    else
        init_args+=(--without-demo=all)
    fi
    if [ -n "${ODOO_LOAD_LANGUAGE:-}" ]; then
        init_args+=(--load-language="${ODOO_LOAD_LANGUAGE}")
    fi

    gosu odoo "${ODOO_SRC}/odoo-bin" "${init_args[@]}"

    # A fresh Odoo database ships with admin/admin. Replace it before the
    # server ever accepts a request.
    if [ -n "${ODOO_ADMIN_PASSWORD:-}" ]; then
        log "setting the admin password"
        gosu odoo "${ODOO_SRC}/odoo-bin" shell \
            -c "${ODOO_RC}" -d "${DB_NAME}" --no-http --log-level=warn <<'PY'
import os

admin = env.ref("base.user_admin")
admin.password = os.environ["ODOO_ADMIN_PASSWORD"]
env.cr.commit()
PY
    else
        log "WARNING: ODOO_ADMIN_PASSWORD is unset — admin still has the default password 'admin'"
    fi

    log "initialisation complete"
else
    log "database already initialised"

    if [ -n "${ODOO_UPDATE_MODULES:-}" ]; then
        log "updating modules: ${ODOO_UPDATE_MODULES}"
        gosu odoo "${ODOO_SRC}/odoo-bin" \
            -c "${ODOO_RC}" -d "${DB_NAME}" -u "${ODOO_UPDATE_MODULES}" \
            --stop-after-init --no-http
    fi
fi
unset PGPASSWORD

# ---------------------------------------------------------------------------
# 5. Serve
# ---------------------------------------------------------------------------
if [ "$1" = "odoo" ]; then
    shift
    set -- "${ODOO_SRC}/odoo-bin" -c "${ODOO_RC}" -d "${DB_NAME}" "$@"
fi

log "starting: $*"
exec gosu odoo "$@"
