#!/bin/bash
# Site admission only: no migration execution/finalization and no Kubernetes API.
set -euo pipefail
umask 077
fail() { printf '%s\n' "Upgrade admission denied: $1" >&2; exit 1; }
# Never emit native client diagnostics (or shell tracing) containing private data.
set +x
private_work= stage=
cleanup() {
  [[ -z "$private_work" ]] || rm -rf -- "$private_work"
  [[ -z "$stage" ]] || rm -rf -- "$stage"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

stable() {
  [[ "$1" =~ ^v?(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || fail 'missing or malformed stable version'
}
chart_info=${CHART_INFO_DIR:-/chart-info}
[[ -r "$chart_info/gitlabVersion" && -r "$chart_info/gitlabChartVersion" ]] || fail 'previous chart-info missing'
previous=$(cat "$chart_info/gitlabVersion")
previous_chart=$(cat "$chart_info/gitlabChartVersion")
target=${GITLAB_VERSION:-}
target_chart=${CHART_VERSION:-}
for version in "$previous" "$previous_chart" "$target" "$target_chart"; do stable "$version"; done
previous=${previous#v}; previous_chart=${previous_chart#v}
target=${target#v}; target_chart=${target_chart#v}
# Reviewed initial model: GitLab CE19.5.x parent statuses 3=finished/6=finalized.
# Source: gitlabhq/gitlabhq@v19.5.0, lib/gitlab/database/background_migration/
# batched_migration.rb. No cross-minor/major required-stop path is admitted yet:
# x.2/x.5/x.8/x.11 stops require separately reviewed latest-patch/source policy.
# This is a compatibility envelope, NOT a second editable target version pin.
[[ "$previous" == 19.5.* && "$target" == 19.5.* &&
   "$previous_chart" == 10.5.* && "$target_chart" == 10.5.* ]] || fail 'unsupported previous model or required-stop path'
(( ${target##*.} >= ${previous##*.} && ${target_chart##*.} >= ${previous_chart##*.} )) || fail 'downgrade'

# Current main/CI share one physical DB; refuse future split/unknown topology.
[[ -n "${PGHOST:-}" && -n "${PGPORT:-}" && -n "${PGDATABASE:-}" && -n "${PGUSER:-}" ]] || fail 'missing DB settings'
[[ "${CI_DB_HOST:-}" == "$PGHOST" && "${CI_DB_PORT:-}" == "$PGPORT" &&
   "${CI_DB_NAME:-}" == "$PGDATABASE" && "${CI_DATABASE_TASKS:-}" == false ]] || fail 'unsupported split main/CI topology'
[[ "$PGHOST" =~ ^[a-zA-Z0-9.-]+$ && "$PGPORT" =~ ^[0-9]{1,5}$ &&
   "$PGDATABASE" =~ ^[a-zA-Z0-9_]+$ && "$PGUSER" =~ ^[a-zA-Z0-9_]+$ ]] || fail 'malformed DB settings'
[[ "$(id -u):$(id -g)" == 1000:1000 ]] || fail 'requires UID/GID1000'
export PGCONNECT_TIMEOUT=10 PGAPPNAME=gitlab-upgrade-admission
export PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=30000 -c lock_timeout=5000 -c idle_in_transaction_session_timeout=30000 -c search_path=public'
# Do not inherit a libpq password/service override. Never put the password in argv
# or environment. Convert the existing raw Secret file to a private libpq file.
unset PGPASSWORD PGSERVICE PGSERVICEFILE
private_work=$(mktemp -d "${WORK_DIR:-/admission-work}/private.XXXXXXXXXXXX") || fail 'private workspace inaccessible'
password_file=${DB_PASSWORD_FILE:-/db-secret/db_password}
[[ -s "$password_file" && -r "$password_file" ]] || fail 'DB password file missing'
password=$(cat "$password_file")
[[ -n "$password" && "$password" != *$'\n'* && "$password" != *$'\r'* ]] || fail 'invalid password file'
password=${password//\\/\\\\}; password=${password//:/\\:}
printf '%s:%s:%s:%s:%s\n' "$PGHOST" "$PGPORT" "$PGDATABASE" "$PGUSER" "$password" > "$private_work/pgpass"
unset password
export PGPASSFILE="$private_work/pgpass"

for client in psql pg_dump pg_restore; do
  client_version=$("$client" --version 2>/dev/null) || fail 'client version unavailable'
  [[ "$client_version" =~ ^[a-z_]+\ \(PostgreSQL\)\ 17\.[0-9]+([\ \(].*)?$ ]] || fail 'requires PostgreSQL17 clients'
done

# Native schema/identity guard, not an inference of GitLab version from a DB row.
# Previous deployed chart-info supplies version semantics; schema_migrations
# fingerprints the actual native schema and is rechecked after the archive.
# Fully qualified native tables cover BOTH logical roles in the shared DB.
# Missing tables/columns/permissions, NULL status and malformed output deny.
observe() {
  local observation
  observation=$(timeout --signal=TERM --kill-after=5s 60s psql -X -A -t -w -v ON_ERROR_STOP=1 2>"$private_work/client-error" <<'SQL'
SELECT current_setting('transaction_read_only'),
       current_setting('server_version_num'), current_database(), current_user,
       host(inet_server_addr()), inet_server_port(), current_schema(),
       CASE WHEN to_regclass('public.application_settings') IS NOT NULL
             AND to_regclass('public.users') IS NOT NULL
             AND to_regclass('public.projects') IS NOT NULL
             AND to_regclass('public.p_ci_builds') IS NOT NULL
             AND EXISTS (SELECT 1 FROM public.schema_migrations)
             AND NOT EXISTS (SELECT 1 FROM public.schema_migrations
                             WHERE version IS NULL OR version !~ '^[0-9]{14}$')
            THEN 'native' ELSE 'unknown' END,
       (SELECT md5(string_agg(version, ',' ORDER BY version)) FROM public.schema_migrations),
       count(*), count(*) FILTER (WHERE status IS NULL OR status NOT IN (3, 6))
FROM public.batched_background_migrations;
SQL
  ) || fail 'read-only DB query failed'
  [[ "$observation" =~ ^on\|17[0-9]{4}\|$PGDATABASE\|$PGUSER\|[0-9a-fA-F:.]+\|[0-9]{1,5}\|public\|native\|[a-f0-9]{32}\|[0-9]+\|0$ ]] || fail 'unsafe or malformed DB observation'
  printf '%s' "$observation"
}
main_before=$(observe)
# Connect again under the CI logical identity; exact endpoint/DB settings were
# compared above. Comparing actual server address/port/DB detects redirection.
ci_before=$(PGHOST="$CI_DB_HOST" PGPORT="$CI_DB_PORT" PGDATABASE="$CI_DB_NAME" observe)
[[ "$main_before" == "$ci_before" ]] || fail 'main/CI identity mismatch'

recovery=${RECOVERY_DIR:-/recovery}
[[ -d "$recovery" && ! -L "$recovery" ]] || fail 'recovery mount absent'
archives="$recovery/db-archives"
if [[ ! -e "$archives" && ! -L "$archives" ]]; then
  mkdir -m 0700 -- "$archives" || fail 'recovery directory unwritable'
fi
# Never repair ownership/modes over an existing share. NAS ACL/squash/capacity
# must be qualified separately; this test requires the private namespace as-is.
[[ -d "$archives" && ! -L "$archives" && "$(stat -c '%u:%g:%a' "$archives")" == 1000:1000:700 ]] || fail 'recovery directory not private UID/GID1000 mode0700'
stage=$(mktemp -d "$archives/.admission.XXXXXXXXXXXX") || fail 'recovery destination unwritable or full'
# Unique partial archive and private metadata; publication is one directory rename.
timeout --signal=TERM --kill-after=10s 600s pg_dump --no-password --format=custom --lock-wait-timeout=5s \
  --file "$stage/database.dump.partial" 2>"$private_work/client-error" || fail 'DB archive failed'
[[ -s "$stage/database.dump.partial" ]] || fail 'empty DB archive'
mv -- "$stage/database.dump.partial" "$stage/database.dump" || fail 'archive rename failed'
(cd "$stage" && sha256sum database.dump > database.sha256) || fail 'archive checksum failed'
timeout --signal=TERM --kill-after=5s 60s pg_restore --list "$stage/database.dump" \
  > "$stage/archive.list" 2>"$private_work/client-error" || fail 'archive unreadable'
[[ -s "$stage/archive.list" ]] || fail 'empty archive listing'
(cd "$stage" && sha256sum --check --status database.sha256) || fail 'archive readback failed'
printf 'previous_gitlab=%s\nprevious_chart=%s\ntarget_gitlab=%s\ntarget_chart=%s\nobserved_at=%s\nidentity=%s\n' \
  "$previous" "$previous_chart" "$target" "$target_chart" "$(date -u +%FT%TZ)" "$main_before" > "$stage/admission.txt"
for file in "$stage"/*; do
  [[ "$(stat -c '%u:%g:%a' "$file")" == 1000:1000:600 ]] || fail 'archive permissions unsafe'
  sync -f "$file" || fail 'archive sync failed'
done
main_after=$(observe)
ci_after=$(PGHOST="$CI_DB_HOST" PGPORT="$CI_DB_PORT" PGDATABASE="$CI_DB_NAME" observe)
[[ "$main_before" == "$main_after" && "$main_after" == "$ci_after" ]] || fail 'DB identity/schema/migration state changed during archive'
published="$archives/${stage##*/.}"
[[ ! -e "$published" && ! -L "$published" ]] || fail 'archive publication collision'
mv -T --no-clobber -- "$stage" "$published" && [[ ! -e "$stage" ]] || fail 'archive publication failed'
stage=
sync -f "$archives" || fail 'archive publication sync failed'
(cd "$published" && sha256sum --check --status database.sha256) || fail 'published archive readback failed'
printf '%s\n' 'Upgrade admission passed: private DB archive readable and checksummed; restore not proven.'
