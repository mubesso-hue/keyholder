#!/usr/bin/env bash
# Applies the migration to a scratch Postgres database with a stubbed Supabase
# auth schema, then runs scripts/test_scenario.sql.
#
# Usage: PGHOST=/tmp PGPORT=5433 PGUSER=postgres scripts/test_schema.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DB="keyholder_test_$$"
psql -v ON_ERROR_STOP=1 -d postgres -qc "create database $DB" >/dev/null
trap 'psql -d postgres -qc "drop database if exists $DB" >/dev/null' EXIT

psql -v ON_ERROR_STOP=1 -d "$DB" -q <<'SQL'
-- Minimal stand-ins for what Supabase provides.
create schema auth;
create table auth.users (id uuid primary key, raw_user_meta_data jsonb not null default '{}'::jsonb);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
do $$ begin
  begin create role anon nologin;          exception when duplicate_object then null; end;
  begin create role authenticated nologin; exception when duplicate_object then null; end;
  begin create role service_role nologin;  exception when duplicate_object then null; end;
end $$;
SQL

echo "== applying migration"
psql -v ON_ERROR_STOP=1 -d "$DB" -q -f supabase/migrations/0001_init.sql

echo "== running scenario"
psql -v ON_ERROR_STOP=1 -d "$DB" -q -f scripts/test_scenario.sql
echo "== all assertions passed"
