#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# P3-B: apply backend/db/schema-p3.sql to a throw-away MariaDB (docker, 127.0.0.1 only)
# and run constraint tests. Only synthetic data. Test password is generated into the
# untracked file backend/db/.test-secret.env and never printed.
# Usage: backend/db/check.sh        Exit code 0 = all checks passed, 1 = a check failed,
#                                   2 = environment problem (docker/image/server).
set -u
cd "$(dirname "$0")"
DOCKER=${DOCKER:-docker}
command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
IMAGE=${MARIADB_IMAGE:-mariadb:lts}
NAME=p3b-mariadb
PORT=${P3B_PORT:-33306}
DB=formtest
SECRET=.test-secret.env

if [ ! -f "$SECRET" ]; then
  ( umask 077; echo "MARIADB_TEST_PW=$(openssl rand -hex 16)" > "$SECRET" )
fi
# shellcheck disable=SC1090
. "./$SECRET"

cleanup() {
  "$DOCKER" stop "$NAME" >/dev/null 2>&1
  "$DOCKER" rm -f "$NAME" >/dev/null 2>&1
  echo "cleanup: container $NAME stopped and removed"
}
trap cleanup EXIT

"$DOCKER" info >/dev/null 2>&1 || { echo "ENV: docker daemon not reachable"; exit 2; }
"$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1 || "$DOCKER" pull "$IMAGE" >/dev/null 2>&1 \
  || { echo "ENV: image $IMAGE not available"; exit 2; }
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1
"$DOCKER" run -d --tmpfs /var/lib/mysql --name "$NAME" -p "127.0.0.1:$PORT:3306" \
  -e MARIADB_ROOT_PASSWORD="$MARIADB_TEST_PW" -e MARIADB_DATABASE=$DB "$IMAGE" >/dev/null \
  || { echo "ENV: container start failed"; exit 2; }

sqlc() { "$DOCKER" exec -i -e MYSQL_PWD="$MARIADB_TEST_PW" "$NAME" mariadb -uroot --batch --skip-column-names "$@"; }

up=0
for _ in $(seq 90); do
  # the entrypoint restarts the server once; require two consecutive successes
  if sqlc -e 'select 1' $DB >/dev/null 2>&1 && sleep 2 && sqlc -e 'select 1' $DB >/dev/null 2>&1; then up=1; break; fi
  sleep 1
done
[ $up = 1 ] || { echo "ENV: server did not become ready"; exit 2; }

echo "server: $(sqlc -e 'select version()')"
echo "image:  $IMAGE ($("$DOCKER" image inspect "$IMAGE" --format '{{.Id}}'))"
echo "bind:   $("$DOCKER" port "$NAME" 3306/tcp)"

# ---- apply schema ----
out=$(sqlc $DB < schema-p3.sql 2>&1); rc=$?
echo "schema apply: exit=$rc output=[${out}]"
[ $rc = 0 ] || { echo "FAIL: schema did not apply"; exit 1; }
echo "tables=$(sqlc -e "select count(*) from information_schema.tables where table_schema='$DB'")" \
     "fks=$(sqlc -e "select count(*) from information_schema.referential_constraints where constraint_schema='$DB'")" \
     "checks=$(sqlc -e "select count(*) from information_schema.check_constraints where constraint_schema='$DB'")" \
     "seeded_permissions=$(sqlc -e "select count(*) from $DB.permission_catalog")"

# ---- test helpers ----
pass=0; fail=0
u() { printf "UNHEX('%032x')" "$1"; }          # synthetic 16-byte id
D() { printf "UNHEX(SHA2('%s',256))" "$1"; }     # synthetic 32-byte digest
NOW="'2026-01-01 00:00:00.000000'"
LATER="'2026-01-02 00:00:00.000000'"
KID="'0123456789abcdef'"
KID2="'fedcba9876543210'"

ok() {   # ok "name" "sql": statement(s) must succeed
  local r; r=$(printf '%s\n' "$2" | sqlc $DB 2>&1); local rc=$?
  if [ $rc = 0 ]; then pass=$((pass+1)); echo "PASS ok   : $1"
  else fail=$((fail+1)); echo "FAIL ok   : $1 -> $r"; fi
}
bad() {  # bad "name" "sql" [errno]: statement must be rejected (optionally with this MariaDB errno)
  local r; r=$(printf '%s\n' "$2" | sqlc $DB 2>&1); local rc=$?
  local no; no=$(printf '%s' "$r" | sed -n 's/^ERROR \([0-9]*\).*/\1/p' | head -1)
  if [ $rc != 0 ] && { [ -z "${3:-}" ] || [ "$no" = "$3" ]; }; then
    pass=$((pass+1)); echo "PASS deny : $1 [errno ${no}]"
  else fail=$((fail+1)); echo "FAIL deny : $1 (rc=$rc errno=${no} want=${3:-any}) $r"; fi
}
eq() {   # eq "name" "sql" expected
  local r; r=$(printf '%s\n' "$2" | sqlc $DB 2>&1)
  if [ "$r" = "$3" ]; then pass=$((pass+1)); echo "PASS eq   : $1 [$r]"
  else fail=$((fail+1)); echo "FAIL eq   : $1 got [$r] want [$3]"; fi
}
FK=1452; DUP=1062; CHK=4025; FKDEL=1451

# ---- fixtures: two tenants c1/c2, forms f1(c1)/f2(c2), account a1/a2 ----
ok "fixture customers/accounts/forms" "
INSERT INTO customers VALUES ($(u 1),'Synthetic C1','active',$NOW),($(u 2),'Synthetic C2','active',$NOW);
INSERT INTO accounts (id,username,password_hash,active,mcp_allowed) VALUES
  ($(u 11),'alice','x',1,0),($(u 12),'bob','x',1,0);
INSERT INTO forms (id,customer_id,name,active) VALUES ($(u 21),$(u 1),'F1',0),($(u 22),$(u 2),'F2',0);
INSERT INTO workflow_versions VALUES ($(u 1),$(u 31),1,'1.0.0','{}',$(D wf),$NOW),($(u 2),$(u 32),1,'1.0.0','{}',$(D wf2),$NOW);
INSERT INTO form_versions (customer_id,form_id,version_no,contract_version,definition_json,definition_sha256,encryption_profile,validation_profile,special_categories,storage_backend,max_upload_bytes,created_at)
  VALUES ($(u 1),$(u 21),1,'1.0.0','{}',$(D fv),'hpke-v2','typed-v1',0,'db',1048576,$NOW),
         ($(u 2),$(u 22),1,'1.0.0','{}',$(D fv2),'hpke-v2','typed-v1',0,'db',1048576,$NOW);
INSERT INTO releases VALUES ($(u 41),$(u 1),$(u 21),1,$(u 31),1,1,'{}',$(D rel),$(u 11),$NOW,$(u 91)),
                            ($(u 42),$(u 2),$(u 22),1,$(u 32),1,1,'{}',$(D rel2),$(u 12),$NOW,$(u 92));
INSERT INTO view_versions VALUES ($(u 1),$(u 21),$(u 141),1,'1.0.0','{}',$(D vv1),$NOW),
                                 ($(u 2),$(u 22),$(u 142),1,'1.0.0','{}',$(D vv2),$NOW);
INSERT INTO release_views VALUES ($(u 1),$(u 21),$(u 41),$(u 141),1),($(u 2),$(u 22),$(u 42),$(u 142),1);
INSERT INTO customer_key_generations (generation_id,customer_id,kid,generation_no,public_key,state,created_at)
  VALUES ($(u 51),$(u 1),$KID,1,UNHEX(REPEAT('ab',32)),'active',$NOW),
         ($(u 52),$(u 2),$KID,1,UNHEX(REPEAT('cd',32)),'active',$NOW);
INSERT INTO customer_memberships VALUES ($(u 1),$(u 11),NULL,'assigned-forms',$NOW);
"

# ---- 1. composite FKs / tenant separation ----
echo "== tenant separation (composite FKs) =="
bad "form_versions: form f1 under customer c2" "INSERT INTO form_versions (customer_id,form_id,version_no,contract_version,definition_json,definition_sha256,encryption_profile,validation_profile,special_categories,storage_backend,max_upload_bytes,created_at) VALUES ($(u 2),$(u 21),9,'1','{}',$(D x),'hpke-v2','typed-v1',0,'db',1,$NOW)" $FK
bad "releases: workflow of c2 referenced by c1 release" "INSERT INTO releases VALUES ($(u 43),$(u 1),$(u 21),1,$(u 32),1,2,'{}',$(D r3),$(u 11),$NOW,$(u 93))" $FK
bad "releases: form_version of other tenant" "INSERT INTO releases VALUES ($(u 44),$(u 1),$(u 22),1,$(u 31),1,2,'{}',$(D r4),$(u 11),$NOW,$(u 94))" $FK
ok  "forms.current_release_id = own release" "UPDATE forms SET current_release_id=$(u 41) WHERE id=$(u 21)"
bad "forms.current_release_id = release of other form/tenant" "UPDATE forms SET current_release_id=$(u 42) WHERE id=$(u 21)" $FK
bad "form_access: grant on form of other tenant" "INSERT INTO form_access VALUES ($(u 1),$(u 11),$(u 22),$NOW)" $FK
bad "form_access: account without membership" "INSERT INTO form_access VALUES ($(u 1),$(u 12),$(u 21),$NOW)" $FK
ok  "form_access: member + own form" "INSERT INTO form_access VALUES ($(u 1),$(u 11),$(u 21),$NOW)"
ok  "submission own tenant + own release" "INSERT INTO submissions (id,customer_id,form_id,release_id,release_evidence,received_at,environment,state,removable,malware_scan_status) VALUES ($(u 61),$(u 1),$(u 21),$(u 41),'recorded',$NOW,'production','accepted',0,'clean')"
bad "submission: release of other tenant" "INSERT INTO submissions (id,customer_id,form_id,release_id,release_evidence,received_at,environment,state,removable,malware_scan_status) VALUES ($(u 62),$(u 1),$(u 21),$(u 42),'recorded',$NOW,'production','accepted',0,'clean')" $FK
bad "submission: release_evidence=recorded without release (CHECK)" "INSERT INTO submissions (id,customer_id,form_id,release_id,release_evidence,received_at,environment,state,removable,malware_scan_status) VALUES ($(u 63),$(u 1),$(u 21),NULL,'recorded',$NOW,'production','accepted',0,'clean')" $CHK
ok  "stored_object own tenant" "INSERT INTO stored_objects (id,customer_id,form_id,submission_id,object_role,backend,ciphertext,packet_format,wrap_kind,kid,content_encoding,ciphertext_sha256,payload_sha256,byte_count,state) VALUES ($(u 71),$(u 1),$(u 21),$(u 61),'data','db',UNHEX('00'),'KUBUS-AEAD:2','hpke',$KID,'raw',$(D o1),$(D p1),1,'ready')"
bad "stored_object: submission of other tenant" "INSERT INTO stored_objects (id,customer_id,form_id,submission_id,object_role,backend,ciphertext,packet_format,wrap_kind,kid,content_encoding,ciphertext_sha256,payload_sha256,byte_count,state) VALUES ($(u 72),$(u 2),$(u 22),$(u 61),'data','db',UNHEX('00'),'KUBUS-AEAD:2','hpke',$KID,'raw',$(D o2),$(D p2),1,'ready')" $FK
bad "stored_object: key generation (kid) of other tenant" "INSERT INTO stored_objects (id,customer_id,form_id,submission_id,object_role,backend,ciphertext,packet_format,wrap_kind,kid,content_encoding,ciphertext_sha256,payload_sha256,byte_count,state) VALUES ($(u 73),$(u 1),$(u 21),$(u 61),'attachment','db',UNHEX('00'),'KUBUS-AEAD:2','hpke',$KID2,'raw',$(D o3),$(D p3),1,'ready')" $FK
bad "stored_object: backend=db with object_key (CHECK)" "INSERT INTO stored_objects (id,customer_id,form_id,submission_id,object_role,backend,object_key,ciphertext,packet_format,wrap_kind,kid,content_encoding,ciphertext_sha256,payload_sha256,byte_count,state) VALUES ($(u 74),$(u 1),$(u 21),$(u 61),'attachment','db','k',UNHEX('00'),'KUBUS-AEAD:2','hpke',$KID,'raw',$(D o4),$(D p4),1,'ready')" $CHK
bad "customers: delete with forms (RESTRICT)" "DELETE FROM customers WHERE id=$(u 1)" $FKDEL
bad "key_access: account without account_keys" "INSERT INTO data_key_access VALUES ($(u 1),$KID,$(u 11),UNHEX(REPEAT('00',32)),UNHEX(REPEAT('00',48)),NULL,$NOW)" $FK

# ---- 2. unique host binding ----
echo "== host binding uniqueness =="
DBI="INSERT INTO domain_bindings (id,customer_id,form_id,host_ascii,environment,release_id,view_id,enabled,changed_by,changed_at,confirmation_audit_id)"
ok  "domain_binding host h.example.test (c1/f1, enabled, release+view+confirmation)" "$DBI VALUES ($(u 81),$(u 1),$(u 21),'h.example.test','production',$(u 41),$(u 141),1,$(u 11),$NOW,$(u 201))"
bad "domain_binding: same host for other tenant" "$DBI VALUES ($(u 82),$(u 2),$(u 22),'h.example.test','production',$(u 42),$(u 142),1,$(u 12),$NOW,$(u 202))" $DUP
bad "domain_binding: same host, other environment" "$DBI VALUES ($(u 83),$(u 1),$(u 21),'h.example.test','test',$(u 41),$(u 141),1,$(u 11),$NOW,NULL)" $DUP
ok  "domain_binding: disable existing" "UPDATE domain_bindings SET enabled=0 WHERE id=$(u 81)"
bad "domain_binding: host still blocked while disabled (UNIQUE spans disabled rows)" "$DBI VALUES ($(u 84),$(u 2),$(u 22),'h.example.test','production',$(u 42),$(u 142),1,$(u 12),$NOW,$(u 203))" $DUP
ok  "domain_binding: host is case-sensitive (ascii_bin; normalization is app duty)" "$DBI VALUES ($(u 85),$(u 2),$(u 22),'H.EXAMPLE.TEST','production',$(u 42),$(u 142),1,$(u 12),$NOW,$(u 204))"
bad "domain_binding: form of other tenant" "$DBI VALUES ($(u 86),$(u 1),$(u 22),'x.example.test','production',$(u 41),$(u 141),1,$(u 11),$NOW,$(u 205))" $FK
bad "domain_binding: enabled without release_id (CHECK)" "$DBI VALUES ($(u 87),$(u 1),$(u 21),'n1.example.test','test',NULL,NULL,1,$(u 11),$NOW,NULL)" $CHK
bad "domain_binding: enabled with release but without view_id (CHECK)" "$DBI VALUES ($(u 88),$(u 1),$(u 21),'n2.example.test','test',$(u 41),NULL,1,$(u 11),$NOW,NULL)" $CHK
bad "domain_binding: production enabled without confirmation_audit_id (CHECK)" "$DBI VALUES ($(u 89),$(u 1),$(u 21),'n3.example.test','production',$(u 41),$(u 141),1,$(u 11),$NOW,NULL)" $CHK
bad "domain_binding: release of other tenant (FK)" "$DBI VALUES ($(u 90),$(u 1),$(u 21),'n4.example.test','test',$(u 42),$(u 142),1,$(u 11),$NOW,NULL)" $FK
bad "domain_binding: changed_by unknown account (FK)" "$DBI VALUES ($(u 93),$(u 1),$(u 21),'n5.example.test','test',$(u 41),$(u 141),1,$(u 999),$NOW,NULL)" $FK
ok  "domain_binding: test env enabled needs no confirmation" "$DBI VALUES ($(u 94),$(u 1),$(u 21),'n6.example.test','test',$(u 41),$(u 141),1,$(u 11),$NOW,NULL)"
ok  "domain_binding: disabled without release/view/confirmation" "$DBI VALUES ($(u 95),$(u 1),$(u 21),'n7.example.test','production',NULL,NULL,0,$(u 11),$NOW,NULL)"
AHF="INSERT INTO api_host_forms (api_host_id,customer_id,form_id,release_id,binding_revision,changed_by,changed_at,confirmation_audit_id)"
ok  "api_hosts + api_host_forms (unbound, release_id NULL)" "INSERT INTO api_hosts VALUES ($(u 87),'api.example.test',1,1); $AHF VALUES ($(u 87),$(u 1),$(u 21),NULL,1,NULL,NULL,NULL)"
bad "api_hosts: duplicate host" "INSERT INTO api_hosts VALUES ($(u 88),'api.example.test',1,1)" $DUP
ok  "api_host_forms: bound to own-tenant release with confirmation" "INSERT INTO api_hosts VALUES ($(u 86),'api2.example.test',1,1); $AHF VALUES ($(u 86),$(u 1),$(u 21),$(u 41),1,$(u 11),$NOW,$(u 91))"
bad "api_host_forms: release of other tenant (FK)" "INSERT INTO api_hosts VALUES ($(u 84),'api4.example.test',1,1); $AHF VALUES ($(u 84),$(u 1),$(u 21),$(u 42),1,$(u 11),$NOW,$(u 91))" $FK
bad "api_host_forms: bound without confirmation_audit_id (CHECK)" "INSERT INTO api_hosts VALUES ($(u 85),'api3.example.test',1,1); $AHF VALUES ($(u 85),$(u 1),$(u 21),$(u 41),1,$(u 11),$NOW,NULL)" $CHK
bad "api_host_forms: form under wrong tenant" "$AHF VALUES ($(u 87),$(u 1),$(u 22),NULL,1,NULL,NULL,NULL)" $FK

# ---- managed_secrets ----
echo "== managed_secrets =="
MS="INSERT INTO managed_secrets (ref,ciphertext,key_version,created_at)"
ok  "managed secret: 60-byte ciphertext" "$MS VALUES ('s1:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',REPEAT('a',60),1,$NOW)"
bad "managed secret: duplicate ref" "$MS VALUES ('s1:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',REPEAT('b',60),1,$NOW)" $DUP
bad "managed secret: ciphertext too short (CHECK)" "$MS VALUES ('s1:bbbbbbbb-aaaa-4aaa-8aaa-aaaaaaaaaaaa',REPEAT('a',10),1,$NOW)" $CHK

# ---- account_enrollments (one-time passkey enrollment tokens) ----
echo "== account_enrollments =="
ENR="INSERT INTO account_enrollments (id,account_id,token_hash,purpose,created_by,created_at,expires_at,consumed_at)"
ok  "enrollment: valid 24 h token" "$ENR VALUES ($(u 7001),$(u 11),$(D enr1),'first-passkey',NULL,$NOW,'2026-01-02 00:00:00.000000',NULL)"
bad "enrollment: same token hash twice" "$ENR VALUES ($(u 7002),$(u 11),$(D enr1),'first-passkey',NULL,$NOW,$LATER,NULL)" $DUP
bad "enrollment: unknown account (FK)" "$ENR VALUES ($(u 7003),$(u 99999),$(D enr2),'first-passkey',NULL,$NOW,$LATER,NULL)" $FK
bad "enrollment: lifetime over 7 days (CHECK)" "$ENR VALUES ($(u 7004),$(u 11),$(D enr3),'recovery-passkey',NULL,$NOW,'2026-01-09 00:00:00.000000',NULL)" $CHK
bad "enrollment: expires before creation (CHECK)" "$ENR VALUES ($(u 7005),$(u 11),$(D enr4),'recovery-passkey',NULL,$LATER,$NOW,NULL)" $CHK

# ---- 3. idempotency reservation ----
echo "== ingest idempotency reservation =="
RES="INSERT INTO ingest_idempotency (customer_id,form_id,key_digest,submission_id,request_digest,digest_key_generation,environment,release_id,release_evidence,result_state,digest_evidence,state,lease_token,lease_until,fence,created_at,expires_at)"
ok  "reserve key K1" "$RES VALUES ($(u 1),$(u 21),$(D K1),$(u 61),$(D req1),1,'production',$(u 41),'recorded','pending','verified','reserved',$(u 101),$LATER,1,$NOW,$LATER)"
bad "reserve same key again (PK collision)" "$RES VALUES ($(u 1),$(u 21),$(D K1),$(u 64),$(D req2),1,'production',$(u 41),'recorded','pending','verified','reserved',$(u 102),$LATER,1,$NOW,$LATER)" $DUP
eq  "INSERT IGNORE on taken key affects 0 rows" "${RES/INSERT INTO/INSERT IGNORE INTO} VALUES ($(u 1),$(u 21),$(D K1),$(u 64),$(D req2),1,'production',$(u 41),'recorded','pending','verified','reserved',$(u 102),$LATER,1,$NOW,$LATER); SELECT ROW_COUNT()" "0"
ok  "same key digest in other tenant is independent" "$RES VALUES ($(u 2),$(u 22),$(D K1),$(u 65),$(D req1),1,'production',$(u 42),'recorded','pending','verified','reserved',$(u 103),$LATER,1,$NOW,$LATER)"
bad "reserve with release of other tenant" "$RES VALUES ($(u 1),$(u 21),$(D K2),$(u 66),$(D r),1,'production',$(u 42),'recorded','pending','verified','reserved',$(u 104),$LATER,1,$NOW,$LATER)" $FK
bad "lease_token without lease_until (CHECK)" "$RES VALUES ($(u 1),$(u 21),$(D K3),$(u 67),$(D r),1,'production',$(u 41),'recorded','pending','verified','reserved',$(u 105),NULL,1,$NOW,$LATER)" $CHK
bad "digest_evidence=verified without request_digest (CHECK)" "$RES VALUES ($(u 1),$(u 21),$(D K4),$(u 68),NULL,NULL,'production',$(u 41),'recorded','pending','verified','reserved',NULL,NULL,0,$NOW,$LATER)" $CHK
ok  "legacy-missing digest + legacy-unknown release (migration shape)" "$RES VALUES ($(u 1),$(u 21),$(D K5),$(u 69),NULL,NULL,'legacy-unknown',NULL,'legacy-unknown','available','legacy-missing','complete',NULL,NULL,0,$NOW,NULL)"
eq  "claim by fence compare-and-swap: 1 row for right fence" "UPDATE ingest_idempotency SET state='complete',lease_token=NULL,lease_until=NULL,fence=2 WHERE customer_id=$(u 1) AND form_id=$(u 21) AND key_digest=$(D K1) AND fence=1; SELECT ROW_COUNT()" "1"
eq  "claim by stale fence: 0 rows" "UPDATE ingest_idempotency SET state='review',fence=3 WHERE customer_id=$(u 1) AND form_id=$(u 21) AND key_digest=$(D K1) AND fence=1; SELECT ROW_COUNT()" "0"

# ---- 4. session with nullable account ----
echo "== sessions with nullable account =="
SES="INSERT INTO sessions (id,token_hash,account_id,state,auth_level,auth_method,authenticated_at,rights_version,csrf_secret_ciphertext,created_at,last_seen_at,idle_expires_at,absolute_expires_at)"
ok  "anonymous session, account NULL" "$SES VALUES ($(u 111),$(D t1),NULL,'anonymous','none',NULL,NULL,NULL,UNHEX('00'),$NOW,$NOW,$LATER,$LATER)"
bad "anonymous session with account (CHECK)" "$SES VALUES ($(u 112),$(D t2),$(u 11),'anonymous','none',NULL,NULL,NULL,UNHEX('00'),$NOW,$NOW,$LATER,$LATER)" $CHK
bad "authenticated session without account (CHECK)" "$SES VALUES ($(u 113),$(D t3),NULL,'authenticated','full','passkey',$NOW,1,UNHEX('00'),$NOW,$NOW,$LATER,$LATER)" $CHK
bad "factor_pending session without account (CHECK)" "$SES VALUES ($(u 114),$(D t4),NULL,'factor_pending','part',NULL,NULL,NULL,UNHEX('00'),$NOW,$NOW,$LATER,$LATER)" $CHK
bad "authenticated session without auth_method (CHECK)" "$SES VALUES ($(u 115),$(D t5),$(u 11),'authenticated','full',NULL,$NOW,1,UNHEX('00'),$NOW,$NOW,$LATER,$LATER)" $CHK
ok  "authenticated session with account" "$SES VALUES ($(u 116),$(D t6),$(u 11),'authenticated','full','passkey',$NOW,1,UNHEX('00'),$NOW,$NOW,$LATER,$LATER)"
bad "session with unknown account (FK)" "$SES VALUES ($(u 117),$(D t7),$(u 999),'factor_pending','part',NULL,NULL,NULL,UNHEX('00'),$NOW,$NOW,$LATER,$LATER)" $FK
bad "session duplicate token_hash" "$SES VALUES ($(u 118),$(D t1),NULL,'anonymous','none',NULL,NULL,NULL,UNHEX('00'),$NOW,$NOW,$LATER,$LATER)" $DUP
ok  "session rotation: replaced_by -> existing session" "UPDATE sessions SET replaced_by=$(u 116),state='revoked',revoked_at=$NOW WHERE id=$(u 111)"
bad "session replaced_by unknown (self-FK)" "UPDATE sessions SET replaced_by=$(u 998) WHERE id=$(u 116)" $FK
ok  "challenge for anonymous session, account NULL" "INSERT INTO auth_challenges (id,session_id,account_id,purpose,challenge_hash,factor_method,created_at,expires_at) VALUES ($(u 121),$(u 111),NULL,'passkey-login',$(D c1),'passkey',$NOW,'2026-01-01 00:02:00.000000')"
bad "challenge passkey-login expires after 121 s (CHECK)" "INSERT INTO auth_challenges (id,session_id,account_id,purpose,challenge_hash,factor_method,created_at,expires_at) VALUES ($(u 123),$(u 111),NULL,'passkey-login',$(D c3),'passkey',$NOW,'2026-01-01 00:02:01.000000')" $CHK
bad "challenge passkey-login without challenge_hash (CHECK)" "INSERT INTO auth_challenges (id,session_id,account_id,purpose,challenge_hash,factor_method,created_at,expires_at) VALUES ($(u 122),$(u 111),NULL,'passkey-login',NULL,'passkey',$NOW,$LATER)" $CHK

# ---- 4b. passkeys (Passkey-Vertrag, VORGESCHLAGEN) ----
echo "== passkeys =="
H11="'00000000-0000-0000-0000-00000000000b'"
H11U="'00000000-0000-0000-0000-00000000000B'"
PK="INSERT INTO passkeys (credential_id,account_id,user_handle,public_key_bytes,public_key_encoding,cose_algorithm,sign_count,label,rp_id,created_at)"
ok  "passkeys: valid insert" "$PK VALUES (UNHEX('a1'),$(u 11),$H11,UNHEX('00'),'pem-spki',-7,0,'t','example.test',$NOW)"
bad "passkeys: wrong public_key_encoding (CHECK)" "$PK VALUES (UNHEX('a2'),$(u 11),$H11,UNHEX('00'),'cose',-7,0,'t','example.test',$NOW)" $CHK
bad "passkeys: cose_algorithm 5 (CHECK)" "$PK VALUES (UNHEX('a3'),$(u 11),$H11,UNHEX('00'),'pem-spki',5,0,'t','example.test',$NOW)" $CHK
bad "passkeys: user_handle wrong length (CHECK)" "$PK VALUES (UNHEX('a4'),$(u 11),'00000000-0000-0000-0000-00000000000',UNHEX('00'),'pem-spki',-7,0,'t','example.test',$NOW)" $CHK
bad "passkeys: user_handle of other account (CHECK)" "$PK VALUES (UNHEX('a5'),$(u 11),'00000000-0000-0000-0000-00000000000c',UNHEX('00'),'pem-spki',-7,0,'t','example.test',$NOW)" $CHK
ok  "passkeys: user_handle upper-case UUID text also valid" "$PK VALUES (UNHEX('a6'),$(u 11),$H11U,UNHEX('00'),'pem-spki',-8,0,'t','example.test',$NOW)"

# ---- 5. duplicate collisions ----
echo "== duplicate collisions =="
bad "accounts: duplicate username" "INSERT INTO accounts (id,username,password_hash,active,mcp_allowed) VALUES ($(u 13),'alice','x',1,0)" $DUP
ok  "accounts: 'Alice' vs 'alice' (utf8mb4_bin is case-sensitive; app must normalize)" "INSERT INTO accounts (id,username,password_hash,active,mcp_allowed) VALUES ($(u 14),'Alice','x',1,0)"
bad "customer_key_generations: second active generation, same customer" "INSERT INTO customer_key_generations (generation_id,customer_id,kid,generation_no,public_key,state,created_at) VALUES ($(u 53),$(u 1),$KID2,2,UNHEX(REPEAT('ee',32)),'active',$NOW)" $DUP
ok  "customer_key_generations: retiring generation alongside active" "INSERT INTO customer_key_generations (generation_id,customer_id,kid,generation_no,public_key,state,created_at) VALUES ($(u 53),$(u 1),$KID2,2,UNHEX(REPEAT('ee',32)),'retiring',$NOW)"
bad "customer_key_generations: duplicate generation_no" "INSERT INTO customer_key_generations (generation_id,customer_id,kid,generation_no,public_key,state,created_at) VALUES ($(u 54),$(u 1),'1111111111111111',2,UNHEX(REPEAT('ee',32)),'retiring',$NOW)" $DUP
bad "customer_key_generations: kid not 16 lowercase hex (CHECK)" "INSERT INTO customer_key_generations (generation_id,customer_id,kid,generation_no,public_key,state,created_at) VALUES ($(u 55),$(u 1),'ZZZZZZZZZZZZZZZZ',3,UNHEX(REPEAT('ee',32)),'retiring',$NOW)" $CHK
bad "customer_key_generations: public_key not 32 bytes (CHECK)" "INSERT INTO customer_key_generations (generation_id,customer_id,kid,generation_no,public_key,state,created_at) VALUES ($(u 56),$(u 1),'2222222222222222',3,UNHEX('aa'),'retiring',$NOW)" $CHK
ok  "form_protocol_keys: current transport key" "INSERT INTO form_protocol_keys (customer_id,form_id,purpose,generation_no,secret_ref,state,created_at) VALUES ($(u 1),$(u 21),'transport',1,'ref:synthetic','current',$NOW)"
bad "form_protocol_keys: second current key same purpose" "INSERT INTO form_protocol_keys (customer_id,form_id,purpose,generation_no,secret_ref,state,created_at) VALUES ($(u 1),$(u 21),'transport',2,'ref:synthetic2','current',$NOW)" $DUP
ok  "form_protocol_keys: previous key with valid_until" "INSERT INTO form_protocol_keys (customer_id,form_id,purpose,generation_no,secret_ref,state,valid_until,created_at) VALUES ($(u 1),$(u 21),'transport',2,'ref:synthetic2','previous',$LATER,$NOW)"
bad "form_protocol_keys: previous without valid_until (CHECK)" "INSERT INTO form_protocol_keys (customer_id,form_id,purpose,generation_no,secret_ref,state,created_at) VALUES ($(u 1),$(u 21),'transport',3,'ref:synthetic3','previous',$NOW)" $CHK
bad "stored_objects: duplicate (submission, role, ordinal)" "INSERT INTO stored_objects (id,customer_id,form_id,submission_id,object_role,backend,ciphertext,packet_format,wrap_kind,kid,content_encoding,ciphertext_sha256,payload_sha256,byte_count,state) VALUES ($(u 75),$(u 1),$(u 21),$(u 61),'data','db',UNHEX('00'),'KUBUS-AEAD:2','hpke',$KID,'raw',$(D o5),$(D p5),1,'ready')" $DUP
ok  "stored_objects: same role, next ordinal" "INSERT INTO stored_objects (id,customer_id,form_id,submission_id,object_role,ordinal_no,backend,ciphertext,packet_format,wrap_kind,kid,content_encoding,ciphertext_sha256,payload_sha256,byte_count,state) VALUES ($(u 76),$(u 1),$(u 21),$(u 61),'data',1,'db',UNHEX('00'),'KUBUS-AEAD:2','hpke',$KID,'raw',$(D o6),$(D p6),1,'ready')"
bad "settings: both safe value and secret_ref NULL (CHECK)" "INSERT INTO settings VALUES ('system','k1',NULL,NULL,1,$NOW)" $CHK
bad "release_version_no duplicate in same form" "INSERT INTO releases VALUES ($(u 45),$(u 1),$(u 21),1,$(u 31),1,1,'{}',$(D r5),$(u 11),$NOW,$(u 95))" $DUP

# ---- 6. Runde 4: digest-hmac key, adapter signers/replays, manifest pin ----
echo "== round 4 additions =="
ok  "form_protocol_keys: current digest-hmac key (secret_ref only)" "INSERT INTO form_protocol_keys (customer_id,form_id,purpose,generation_no,secret_ref,state,created_at) VALUES ($(u 1),$(u 21),'digest-hmac',1,'ref:synthetic-digest','current',$NOW)"
bad "form_protocol_keys: digest-hmac with public_key (CHECK)" "INSERT INTO form_protocol_keys (customer_id,form_id,purpose,generation_no,public_key,secret_ref,state,created_at) VALUES ($(u 1),$(u 21),'digest-hmac',2,UNHEX(SHA2('pk',256)),'ref:x','previous',$NOW)" $CHK
ok  "adapter binding fixture" "INSERT INTO legacy_adapter_bindings (id,customer_id,form_id,adapter_identity,service_cert_sha256,ua_secret_ref,ip_secret_ref,activated_at,expires_at) VALUES ($(u 201),$(u 1),$(u 21),'adapter-synthetic',$(D cert1),'ref:ua','ref:ip',$NOW,$LATER)"
ok  "adapter_signers: first signer" "INSERT INTO adapter_signers (binding_id,customer_id,form_id,generation_no,public_key,state,created_at) VALUES ($(u 201),$(u 1),$(u 21),1,$(D pub1),'current',$NOW)"
bad "adapter_signers: duplicate public_key (other generation)" "INSERT INTO adapter_signers (binding_id,customer_id,form_id,generation_no,public_key,state,valid_until,created_at) VALUES ($(u 201),$(u 1),$(u 21),2,$(D pub1),'previous',$LATER,$NOW)" $DUP
ok  "adapter_signers: second signer, distinct key" "INSERT INTO adapter_signers (binding_id,customer_id,form_id,generation_no,public_key,state,valid_until,created_at) VALUES ($(u 201),$(u 1),$(u 21),2,$(D pub2),'previous',$LATER,$NOW)"
AR="INSERT INTO adapter_replays (binding_id,customer_id,form_id,generation_no,text_sha256,created_at,expires_at)"
ok  "adapter_replays: expires_at = created_at + 600 s accepted" "$AR VALUES ($(u 201),$(u 1),$(u 21),1,$(D t1),'2026-01-01 00:00:00.000000','2026-01-01 00:10:00.000000')"
bad "adapter_replays: expires_at = created_at + 599 s rejected (CHECK)" "$AR VALUES ($(u 201),$(u 1),$(u 21),1,$(D t2),'2026-01-01 00:00:00.000000','2026-01-01 00:09:59.000000')" $CHK
bad "adapter_replays: duplicate (binding, text_sha256)" "$AR VALUES ($(u 201),$(u 1),$(u 21),1,$(D t1),'2026-01-01 00:00:00.000000','2026-01-01 01:00:00.000000')" $DUP
bad "adapter_replays: unknown signer generation (FK)" "$AR VALUES ($(u 201),$(u 1),$(u 21),9,$(D t3),'2026-01-01 00:00:00.000000','2026-01-01 01:00:00.000000')" $FK
bad "submissions: manifest object without payload pin (CHECK)" "UPDATE submissions SET mail_manifest_object_id=$(u 71) WHERE id=$(u 61)" $CHK
bad "submissions: payload pin without manifest object (CHECK)" "UPDATE submissions SET mail_manifest_payload_sha256=$(D p1) WHERE id=$(u 61)" $CHK
bad "submissions: manifest pin with wrong payload_sha256 (FK)" "UPDATE submissions SET mail_manifest_object_id=$(u 71),mail_manifest_payload_sha256=$(D wrong) WHERE id=$(u 61)" $FK
ok  "submissions: manifest pin with matching payload_sha256" "UPDATE submissions SET mail_manifest_object_id=$(u 71),mail_manifest_payload_sha256=$(D p1) WHERE id=$(u 61)"

# ---- 7. P5-B E1: form_drafts (draft persistence, VORGESCHLAGEN) ----
echo "== form_drafts =="
DR="INSERT INTO form_drafts (id,customer_id,form_id,revision,base_release_id,document_json,document_sha256,created_by,created_at,updated_by,updated_at)"
ok  "form_drafts: draft of f1 under c1, based on own release" "$DR VALUES ($(u 301),$(u 1),$(u 21),1,$(u 41),'{}',$(D d1),$(u 11),$NOW,$(u 11),$NOW)"
ok  "form_drafts: draft without base release (NULL)" "$DR VALUES ($(u 302),$(u 1),$(u 21),1,NULL,'{}',$(D d2),$(u 11),$NOW,$(u 11),$NOW)"
bad "form_drafts: form f1 under customer c2 (composite FK)" "$DR VALUES ($(u 303),$(u 2),$(u 21),1,NULL,'{}',$(D d3),$(u 11),$NOW,$(u 11),$NOW)" $FK
bad "form_drafts: base release of other tenant (composite FK)" "$DR VALUES ($(u 304),$(u 1),$(u 21),1,$(u 42),'{}',$(D d4),$(u 11),$NOW,$(u 11),$NOW)" $FK
bad "form_drafts: revision 0 (CHECK)" "$DR VALUES ($(u 305),$(u 1),$(u 21),0,NULL,'{}',$(D d5),$(u 11),$NOW,$(u 11),$NOW)" $CHK
bad "form_drafts: updated_at before created_at (CHECK)" "$DR VALUES ($(u 306),$(u 1),$(u 21),1,NULL,'{}',$(D d6),$(u 11),$LATER,$(u 11),$NOW)" $CHK
bad "form_drafts: unknown creator (FK)" "$DR VALUES ($(u 307),$(u 1),$(u 21),1,NULL,'{}',$(D d7),$(u 999),$NOW,$(u 11),$NOW)" $FK
bad "form_drafts: duplicate id" "$DR VALUES ($(u 301),$(u 1),$(u 21),1,NULL,'{}',$(D d8),$(u 11),$NOW,$(u 11),$NOW)" $DUP
bad "form_drafts: document_sha256 NULL (NOT NULL)" "$DR VALUES ($(u 308),$(u 1),$(u 21),1,NULL,'{}',NULL,$(u 11),$NOW,$(u 11),$NOW)"
ok  "form_drafts: conditional revision update (If-Match 1 -> 2) affects one row" "UPDATE form_drafts SET revision=2,document_sha256=$(D d1b),updated_at=$LATER WHERE id=$(u 301) AND revision=1"
eq  "form_drafts: stale If-Match (revision=1) updates no row" "UPDATE form_drafts SET revision=3 WHERE id=$(u 301) AND revision=1; SELECT ROW_COUNT();" 0
PC="INSERT INTO publication_confirmations (id,session_id,account_id,customer_id,form_id,draft_id,draft_revision,candidate_sha256,authenticated_at,created_at,expires_at)"
ok  "publication_confirmations: bound to existing draft of same form" "$PC VALUES ($(u 311),$(u 116),$(u 11),$(u 1),$(u 21),$(u 301),2,$(D d1b),$NOW,$NOW,'2026-01-01 00:02:00.000000')"
bad "publication_confirmations: unknown draft (FK)" "$PC VALUES ($(u 312),$(u 116),$(u 11),$(u 1),$(u 21),$(u 999),1,$(D d9),$NOW,$NOW,'2026-01-01 00:02:00.000000')" $FK
bad "publication_confirmations: draft id of other form (composite FK)" "$PC VALUES ($(u 313),$(u 116),$(u 11),$(u 2),$(u 22),$(u 301),1,$(D d10),$NOW,$NOW,'2026-01-01 00:02:00.000000')" $FK
bad "form_drafts: delete draft referenced by confirmation (RESTRICT)" "DELETE FROM form_drafts WHERE id=$(u 301)" $FKDEL
eq  "permission_catalog seed has 29 entries (E6: seed lives in schema)" "SELECT COUNT(*) FROM permission_catalog" 29

echo
# P11-E: consent persistence constraints (no live OAuth protocol calls).
eq "OAuth consent table present" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB' AND table_name='oauth_authorization_requests'" "1"
eq "OAuth grant boundary required" "SELECT IS_NULLABLE FROM information_schema.columns WHERE table_schema='$DB' AND table_name='oauth_grants' AND column_name='scope_json'" "NO"
eq "OAuth S256 constraint present" "SELECT COUNT(*) FROM information_schema.check_constraints WHERE constraint_schema='$DB' AND constraint_name='ck_oauth_code_s256'" "1"
bad "OAuth consent requires existing session/client" "INSERT INTO oauth_authorization_requests (id,session_id,client_id,redirect_uri,code_challenge,scopes_json,state_value,resource,expires_at) VALUES ($(u 9001),$(u 9002),$(u 9003),'https://client.test/cb',REPEAT('a',43),'[]','','https://public.test/mcp/',$LATER)" $FK

echo "RESULT: pass=$pass fail=$fail"
[ $fail = 0 ] && exit 0 || exit 1
