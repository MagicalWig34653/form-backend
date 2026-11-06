#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# COPY into the runtime image on main; deployment mounts this wrapper until then.
set -euo pipefail
umask 077
fail() { printf 'entrypoint: %s\n' "$*" >&2; exit 64; }
# Port files cannot agree reliably with ports rendered by the orchestrator.
for name in FORM_HTTP_PORT FORM_PUBLIC_PORT FORM_INTERNAL_PORT; do
  file_var="${name}_FILE"
  [[ -z "${!file_var:-}" ]] || fail "$file_var wird nicht unterstützt; Port direkt setzen"
done
# Scalar file overrides are explicit; native secret-path variables are handled separately.
for name in FORM_INTERNAL_SECOND_FACTOR FORM_PUBLIC_DASHBOARD FORM_PUBLIC_DASHBOARD_HOSTS FORM_PUBLIC_TRUSTED_PROXIES FORM_INTERNAL_TRUSTED_PROXIES FORM_HTTP_HOST FORM_LOG_LEVEL FORM_DB_HOST FORM_DB_PORT FORM_DB_USER FORM_DB_NAME FORM_DB_TLS FORM_ALLOW_INSECURE_DEV FORM_SCHEMA_FILE FORM_PUBLIC_DIR FORM_TRUSTED_PROXIES FORM_MAIL_ALLOWED_NETS FORM_ADMIN_ORIGIN FORM_RP_ID FORM_SDK_DIR FORM_OPS_THRESHOLD FORM_OPS_INTERVAL_SECONDS FORM_OPS_RETENTION_DAYS FORM_OPS_RECIPIENT FORM_OPS_SENDER FORM_OPS_CONNECTION FORM_ABUSE_BLOCKED_NETS FORM_ABUSE_UA_PATTERNS FORM_ABUSE_HASHES FORM_ABUSE_THRESHOLD FORM_ABUSE_WINDOW_SECONDS FORM_ABUSE_BAN_SECONDS FORM_MAIL_RESTRICTED FORM_MAIL_ALLOWED_RECIPIENTS FORM_MIGRATION_ALLOWED_NETS FORM_WEBHOOK_MAX_PER_FORM FORM_WEBHOOK_MAX_PER_CUSTOMER FORM_WEBHOOK_MAX_BACKLOG_PER_CUSTOMER FORM_MCP_TOKEN_RATE_LIMIT FORM_INGEST_REQUESTS_PER_MINUTE FORM_OAUTH_AUTHORIZE_BASE_URL FORM_OAUTH_REGISTRATIONS_PER_HOUR FORM_OAUTH_MAX_UNUSED_CLIENTS FORM_OAUTH_ISSUER LOG_LEVEL; do
  file_var="${name}_FILE"
  file=${!file_var:-}
  [[ -n "$file" ]] || continue
  [[ -r "$file" ]] || fail "$file_var ist nicht lesbar"
  value=$(cat "$file")
  export "$name=$value"
done
# Native DB password files need no conversion. Reject ambiguous secret sources.
if [[ -n "${FORM_DB_PASSWORD:-}" && -n "${FORM_DB_PASSWORD_FILE:-}" ]]; then
  fail 'FORM_DB_PASSWORD und FORM_DB_PASSWORD_FILE sind beide gesetzt'
fi
# Convenience ENV aliases for secrets whose Swift interface only accepts a path.
for name in FORM_SERVER_KEY FORM_BOOTSTRAP_PASSWORD; do
  file_var="${name}_FILE"
  value=${!name:-}
  file=${!file_var:-}
  if [[ -n "$value" ]]; then
    [[ -z "$file" ]] || fail "$name und $file_var sind beide gesetzt"
    dir=$(mktemp -d)
    chmod 700 "$dir"
    printf '%s' "$value" > "$dir/value"
    chmod 400 "$dir/value"
    export "$file_var=$dir/value"
    unset "$name"
  fi
done
# Optional bootstrap secret: a marker means use main.swift's generated one-time password.
if [[ -n "${FORM_BOOTSTRAP_PASSWORD_FILE:-}" && -r "$FORM_BOOTSTRAP_PASSWORD_FILE" ]]; then
  value=$(cat "$FORM_BOOTSTRAP_PASSWORD_FILE")
  [[ "$value" != FORM_OPTIONAL_UNSET ]] || unset FORM_BOOTSTRAP_PASSWORD_FILE
fi
exec "${FORM_APP_BINARY:-/app/App}" "$@"
