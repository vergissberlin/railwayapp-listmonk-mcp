#!/bin/sh
# Zero-touch bootstrap for listmonk on Railway:
#   1. install the schema on first boot (idempotent) incl. admin + API user
#   2. run pending migrations on upgrades
#   3. pin the API user's token to LISTMONK_API_TOKEN so the MCP service can
#      authenticate without any manual step
#   4. set app.root_url to the public domain while it is still the default
set -eu
# busybox ash supports pipefail; needed so install/upgrade failures abort the boot.
set -o pipefail

cd /listmonk

port="${PORT:-9000}"
export LISTMONK_app__address="0.0.0.0:${port}"

: "${LISTMONK_db__host:?LISTMONK_db__host is required}"
: "${LISTMONK_db__user:?LISTMONK_db__user is required}"
: "${LISTMONK_db__password:?LISTMONK_db__password is required}"
: "${LISTMONK_db__database:?LISTMONK_db__database is required}"

export PGHOST="${LISTMONK_db__host}"
export PGPORT="${LISTMONK_db__port:-5432}"
export PGUSER="${LISTMONK_db__user}"
export PGPASSWORD="${LISTMONK_db__password}"
export PGDATABASE="${LISTMONK_db__database}"
export PGSSLMODE="${LISTMONK_db__ssl_mode:-prefer}"
export PGCONNECT_TIMEOUT=5

echo "railway-entrypoint: waiting for Postgres at ${PGHOST}:${PGPORT}"
i=0
until pg_isready -q; do
	i=$((i + 1))
	if [ "$i" -ge 60 ]; then
		echo "railway-entrypoint: Postgres not reachable after 120s" >&2
		exit 1
	fi
	sleep 2
done

# The API user is only created by --install when LISTMONK_ADMIN_API_USER is set.
export LISTMONK_ADMIN_API_USER="${LISTMONK_ADMIN_API_USER:-${LISTMONK_API_USER:-}}"

# --install prints a random API token to stderr; drop that line so no secret
# ends up in the deploy logs (the token is replaced below anyway).
./listmonk --install --idempotent --yes 2>&1 | sed '/LISTMONK_ADMIN_API_TOKEN=/d'
./listmonk --upgrade --yes 2>&1 | sed '/LISTMONK_ADMIN_API_TOKEN=/d'

if [ -n "${LISTMONK_API_USER:-}" ] && [ -n "${LISTMONK_API_TOKEN:-}" ]; then
	psql -v ON_ERROR_STOP=1 -q -X \
		-v api_user="${LISTMONK_API_USER}" \
		-v api_token="${LISTMONK_API_TOKEN}" <<'SQL'
INSERT INTO users (username, password_login, password, email, name, type, user_role_id, status)
SELECT :'api_user', false,
       encode(sha256(convert_to(:'api_token', 'UTF8')), 'hex'),
       :'api_user' || '@api', :'api_user', 'api',
       (SELECT id FROM roles WHERE type = 'user' AND name = 'Super Admin' ORDER BY id LIMIT 1),
       'enabled'
WHERE EXISTS (SELECT 1 FROM roles WHERE type = 'user' AND name = 'Super Admin')
ON CONFLICT (username) DO UPDATE
   SET password = EXCLUDED.password, status = 'enabled', updated_at = NOW()
 WHERE users.type = 'api';
SQL
	echo "railway-entrypoint: API user '${LISTMONK_API_USER}' token synced"
fi

if [ -n "${LISTMONK_ROOT_URL:-}" ]; then
	psql -v ON_ERROR_STOP=1 -q -X -v root_url="${LISTMONK_ROOT_URL}" <<'SQL'
UPDATE settings SET value = to_jsonb(:'root_url'::text), updated_at = NOW()
 WHERE key = 'app.root_url' AND value = '"http://localhost:9000"'::jsonb;
SQL
fi

mkdir -p /listmonk/uploads

exec /usr/local/bin/docker-entrypoint.sh "$@"
