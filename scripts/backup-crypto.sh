#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Backup encryption helpers (age preferred, gpg alternative). Only public keys live on the server.
# Plaintext SQL is only ever piped into the encryptor, never written to disk.
set -euo pipefail

crypto_gpg_home=
crypto_cleanup() {
  if [[ -n "$crypto_gpg_home" ]]; then
    gpgconf --homedir "$crypto_gpg_home" --kill all >/dev/null 2>&1 || true
    rm -rf "$crypto_gpg_home"
  fi
}

# Sets BACKUP_CRYPTO to age|gpg|none and BACKUP_DATA_FILE; fails closed without a recipient.
crypto_select() {
  local age=${FORM_BACKUP_AGE_RECIPIENTS_FILE:-} gpg=${FORM_BACKUP_GPG_RECIPIENT:-}
  if [[ -n "$age" && -n "$gpg" ]]; then db_fail 'FORM_BACKUP_AGE_RECIPIENTS_FILE und FORM_BACKUP_GPG_RECIPIENT sind beide gesetzt; genau eines wählen'; fi
  if [[ -n "$age" ]]; then
    command -v age >/dev/null || db_fail 'age fehlt'
    [[ -r "$age" && -s "$age" ]] || db_fail 'FORM_BACKUP_AGE_RECIPIENTS_FILE nicht lesbar oder leer'
    ! grep -q 'AGE-SECRET-KEY' "$age" || db_fail 'Empfängerdatei enthält einen privaten Schlüssel; nur öffentliche Schlüssel (age1...) darf der Server kennen'
    BACKUP_CRYPTO=age; BACKUP_DATA_FILE=database.sql.age
  elif [[ -n "$gpg" ]]; then
    command -v gpg >/dev/null || db_fail 'gpg fehlt'
    [[ -n "${FORM_BACKUP_GPG_PUBKEY_FILE:-}" && -r "${FORM_BACKUP_GPG_PUBKEY_FILE:-}" ]] || db_fail 'FORM_BACKUP_GPG_PUBKEY_FILE (öffentlicher Schlüssel zum Import) fehlt oder ist nicht lesbar'
    ! grep -q 'PRIVATE KEY BLOCK' "$FORM_BACKUP_GPG_PUBKEY_FILE" || db_fail 'Schlüsseldatei enthält einen privaten Schlüssel; nur öffentliche Schlüssel'
    BACKUP_CRYPTO=gpg; BACKUP_DATA_FILE=database.sql.gpg
  elif [[ "${FORM_BACKUP_ALLOW_PLAINTEXT:-0}" == 1 ]]; then
    BACKUP_CRYPTO=none; BACKUP_DATA_FILE=database.sql
    printf 'WARNUNG: FORM_BACKUP_ALLOW_PLAINTEXT=1 - Backup wird UNVERSCHLÜSSELT geschrieben. Nur für Entwicklung, nie für echte Daten.\n' >&2
  else
    db_fail 'Kein Backup-Empfänger konfiguriert (FORM_BACKUP_AGE_RECIPIENTS_FILE oder FORM_BACKUP_GPG_RECIPIENT + FORM_BACKUP_GPG_PUBKEY_FILE). Abbruch; Klartext nur mit FORM_BACKUP_ALLOW_PLAINTEXT=1 (Entwicklung).'
  fi
}

# stdin -> stdout
crypto_encrypt() {
  case "$BACKUP_CRYPTO" in
    age) age --encrypt -R "$FORM_BACKUP_AGE_RECIPIENTS_FILE" ;;
    gpg)
      if [[ -z "$crypto_gpg_home" ]]; then
        crypto_gpg_home=$(mktemp -d "${TMPDIR:-/tmp}/fbg.XXXXXX")
        chmod 700 "$crypto_gpg_home"
        gpg --homedir "$crypto_gpg_home" --batch --quiet --import "$FORM_BACKUP_GPG_PUBKEY_FILE" 2>/dev/null
      fi
      gpg --homedir "$crypto_gpg_home" --batch --quiet --trust-model always --encrypt --recipient "$FORM_BACKUP_GPG_RECIPIENT" --output - ;;
    none) cat ;;
  esac
}

# file -> stdout
crypto_decrypt() {
  local file=$1
  case "$BACKUP_CRYPTO" in
    age) age --decrypt -i "$FORM_BACKUP_AGE_IDENTITY_FILE" "$file" ;;
    gpg) gpg --homedir "${FORM_BACKUP_GPG_HOME:-$HOME/.gnupg}" --batch --quiet --decrypt "$file" ;;
    none) cat "$file" ;;
  esac
}

# Detects the data file of a backup directory (exactly one) and validates decryption settings.
crypto_detect() {
  local dir=$1 found=() f
  for f in database.sql.age database.sql.gpg database.sql; do [[ ! -e "$dir/$f" ]] || found+=("$f"); done
  (( ${#found[@]} == 1 )) || db_fail 'Backup muss genau eine Datendatei enthalten (database.sql.age, .gpg oder database.sql)'
  BACKUP_DATA_FILE=${found[0]}
  case "$BACKUP_DATA_FILE" in
    database.sql.age)
      BACKUP_CRYPTO=age; command -v age >/dev/null || db_fail 'age fehlt'
      [[ -n "${FORM_BACKUP_AGE_IDENTITY_FILE:-}" && -r "${FORM_BACKUP_AGE_IDENTITY_FILE:-}" ]] || db_fail 'FORM_BACKUP_AGE_IDENTITY_FILE (privater Schlüssel, nur auf dem Wiederherstellungsrechner) fehlt' ;;
    database.sql.gpg) BACKUP_CRYPTO=gpg; command -v gpg >/dev/null || db_fail 'gpg fehlt' ;;
    database.sql)
      [[ "${FORM_BACKUP_ALLOW_PLAINTEXT:-0}" == 1 ]] || db_fail 'Klartext-Backup; Restore nur mit FORM_BACKUP_ALLOW_PLAINTEXT=1 (Entwicklung)'
      BACKUP_CRYPTO=none ;;
  esac
}
