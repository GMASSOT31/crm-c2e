#!/usr/bin/env bash
# Lance les tests du Lot 1 sur un Postgres local jetable (aucun service externe).
set -euo pipefail
cd "$(dirname "$0")/.."
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | tail -1)
D=$(mktemp -d); chown postgres "$D" 2>/dev/null || true
run() { su postgres -c "$*" 2>/dev/null || bash -c "$*"; }
run "$PGBIN/initdb -D $D/data -A trust >/dev/null"
run "$PGBIN/pg_ctl -D $D/data -o '-p 54399 -k $D' -l $D/log -w start >/dev/null"
trap 'run "$PGBIN/pg_ctl -D $D/data stop >/dev/null"; rm -rf "$D"' EXIT
P="psql -v ON_ERROR_STOP=1 -q -h $D -p 54399 -U postgres -d postgres"
$P -f tests/auth_stub.sql
$P -f supabase/migrations/20261026000001_socle.sql
$P -f supabase/seed_demo.sql
$P -f tests/lot1.sql | grep -v '^$'
