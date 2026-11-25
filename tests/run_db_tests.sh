#!/usr/bin/env bash
# Builds a fresh database from db/*.sql and runs tests/db_tests.sql.
# Usage: PGURL=postgresql://postgres:postgres@localhost:5432/postgres tests/run_db_tests.sh
set -euo pipefail
cd "$(dirname "$0")/.."
PGURL=${PGURL:-postgresql://postgres:postgres@localhost:5432/postgres}
DB=fronter_test
psql "$PGURL" -q -c "drop database if exists $DB" -c "create database $DB"
TEST_URL="${PGURL%/*}/$DB"
psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -f tests/supabase_stub.sql
for f in db/0*.sql; do echo "== $f"; psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -f "$f"; done
psql "$TEST_URL" -qtA -v ON_ERROR_STOP=1 -f tests/db_tests.sql 2>&1 | sed "s/^psql:[^ ]* NOTICE:  //" | grep -v "^$"
