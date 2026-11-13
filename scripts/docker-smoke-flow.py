#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Browser-free administration flow for scripts/docker-build.sh (smoke test of the release image).

Two sub-commands, both standard library only (ES256 signing and X25519 keys come from the openssl CLI):

  docker-smoke-flow.py seed WORKDIR
      Generates a synthetic passkey (EC P-256) and prints SQL (account, passkey, rights) on stdout. Key material stays in WORKDIR.
  docker-smoke-flow.py run WORKDIR
      Environment: SMOKE_ADMIN_ORIGIN (e.g. http://localhost:38081). Logs in with the passkey (a real WebAuthn assertion that
      the server verifies), creates customer, customer key, form, publishes the standard draft, issues SDK credentials
      (WORKDIR/sdk.json, mode 0600) and prints the ids as KEY=value lines on stdout; progress goes to stderr.

Everything is synthetic and random per run. Passkey login is the real code path; the browser-side key set-up (account key
wrapped by the passkey PRF, recovery code) is NOT covered: the customer key is registered without the optional access grant.
"""
import base64
import hashlib
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
import uuid

RP_ID = "localhost"


def b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def b64u_dec(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def openssl(*args: str, data: bytes | None = None) -> bytes:
    return subprocess.run(["openssl", *args], input=data, check=True, capture_output=True).stdout


def seed(work: str) -> None:
    account = str(uuid.uuid4())
    key = os.path.join(work, "passkey.pem")
    fd = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout"))
    pub = openssl("pkey", "-in", key, "-pubout").decode().strip()
    cred = os.urandom(32)
    with open(os.path.join(work, "passkey.json"), "w") as f:
        json.dump({"account": account, "credential": b64u(cred)}, f)
    rights = ["system.manage", "form.create", "form.read", "draft.write", "release.publish", "key.manage"]
    union = " UNION ".join(f"SELECT '{r}' AS p" for r in rights)
    print(f"""INSERT INTO accounts (id, username, password_hash, active, mcp_allowed, rights_version, created_at)
VALUES (UNHEX(REPLACE('{account}','-','')), 'smoke-user', '', 1, 0, 1, UTC_TIMESTAMP(6));
INSERT INTO passkeys (credential_id, account_id, user_handle, public_key_bytes, public_key_encoding, cose_algorithm, sign_count, label, rp_id, created_at)
VALUES (UNHEX('{cred.hex()}'), UNHEX(REPLACE('{account}','-','')), '{account}', '{pub}', 'pem-spki', -7, 0, 'smoke', '{RP_ID}', UTC_TIMESTAMP(6));
INSERT INTO permission_assignments (id, account_id, permission, scope_kind, customer_id, form_id, revision, granted_by, granted_at)
SELECT UNHEX(REPLACE(UUID(),'-','')), UNHEX(REPLACE('{account}','-','')), p, 'system', NULL, NULL, 1, UNHEX(REPLACE('{account}','-','')), UTC_TIMESTAMP(6)
FROM ({union}) AS rights;""")


class Admin:
    def __init__(self, origin: str, work: str) -> None:
        self.origin, self.work = origin, work
        self.cookie = ""
        self.csrf = ""
        self.counter = 0
        with open(os.path.join(work, "passkey.json")) as f:
            meta = json.load(f)
        self.account, self.cred = meta["account"], meta["credential"]

    def call(self, method: str, path: str, body=None, headers=None, expect=(200, 201)):
        data = None if body is None else json.dumps(body).encode()
        h = {"Origin": self.origin, "Accept": "application/json", "X-CSRF-Token": self.csrf}
        if body is not None:
            h["Content-Type"] = "application/json"
        if self.cookie:
            h["Cookie"] = self.cookie
        h.update(headers or {})
        req = urllib.request.Request(self.origin + path, data=data, method=method, headers=h)
        try:
            resp = urllib.request.urlopen(req, timeout=30)
        except urllib.error.HTTPError as e:
            resp = e
        raw = resp.read()
        for value in resp.headers.get_all("Set-Cookie") or []:
            self.cookie = value.split(";", 1)[0]
        parsed = json.loads(raw) if raw[:1] in (b"{", b"[") else None
        if resp.status not in expect:
            detail = (parsed or {}).get("code") or (parsed or {}).get("title") or raw[:120].decode(errors="replace")
            raise SystemExit(f"FAIL {method} {path}: HTTP {resp.status} {detail}")
        if isinstance(parsed, dict) and "csrfToken" in parsed:
            self.csrf = parsed["csrfToken"]
        return parsed

    def assertion(self, challenge: str) -> dict:
        self.counter += 1
        client = json.dumps({"type": "webauthn.get", "challenge": challenge, "origin": self.origin}, separators=(",", ":")).encode()
        auth = hashlib.sha256(RP_ID.encode()).digest() + bytes([0x05]) + self.counter.to_bytes(4, "big")
        sig = openssl("dgst", "-sha256", "-sign", os.path.join(self.work, "passkey.pem"), data=auth + hashlib.sha256(client).digest())
        return {"id": self.cred, "rawId": self.cred, "type": "public-key",
                "response": {"authenticatorData": b64u(auth), "clientDataJSON": b64u(client), "signature": b64u(sig),
                             "userHandle": b64u(self.account.encode())}}

    def login(self) -> None:
        self.call("GET", "/admin/api/v1/auth/session")
        opts = self.call("POST", "/admin/api/v1/auth/passkey/options", {})
        res = self.call("POST", "/admin/api/v1/auth/passkey/verify",
                        {"challengeId": opts["challengeId"], "credential": self.assertion(opts["publicKey"]["challenge"])})
        if res.get("state") != "authenticated":
            raise SystemExit(f"FAIL login state {res.get('state')}")


def run(work: str) -> None:
    def log(msg: str) -> None:
        print(msg, file=sys.stderr, flush=True)

    admin = Admin(os.environ["SMOKE_ADMIN_ORIGIN"], work)
    admin.login()
    log("ok   passkey login (real WebAuthn assertion verified by the server)")
    tenant = admin.call("POST", "/admin/api/v1/tenants", {"name": "Smoke-Kunde"})["id"]
    log("ok   customer created")
    xkey = os.path.join(work, "datakey.pem")
    fd = os.open(xkey, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(openssl("genpkey", "-algorithm", "X25519"))
    pub = openssl("pkey", "-in", xkey, "-pubout", "-outform", "DER")[-32:]
    admin.call("PUT", f"/admin/api/v1/tenants/{tenant}/customer-key", {"publicKey": b64u(pub)})
    log("ok   customer data key (X25519 public key) registered")
    form = admin.call("POST", f"/admin/api/v1/tenants/{tenant}/forms", {"name": "Smoke-Formular"})["id"]
    detail = admin.call("GET", f"/admin/api/v1/tenants/{tenant}/forms/{form}")
    draft = admin.call("GET", f"/admin/api/v1/tenants/{tenant}/forms/{form}/drafts/{detail['draftIds'][0]}")
    log("ok   form created with standard draft")
    conf = admin.call("POST", f"/admin/api/v1/tenants/{tenant}/forms/{form}/publication-confirmations",
                      {"draftId": draft["id"], "revision": draft["revision"], "hash": draft["hash"], "confirm": True})
    admin.call("POST", f"/admin/api/v1/tenants/{tenant}/forms/{form}/releases",
               {"draftId": draft["id"], "revision": draft["revision"], "hash": draft["hash"], "confirmationId": conf["confirmationId"]},
               headers={"Idempotency-Key": str(uuid.uuid4())})
    log("ok   release published")
    creds = admin.call("POST", f"/admin/api/v1/tenants/{tenant}/forms/{form}/sdk-credentials")
    sdk = os.path.join(work, "sdk.json")
    fd = os.open(sdk, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(creds, f)
    log("ok   SDK credentials issued")
    print(f"SMOKE_TENANT={tenant}\nSMOKE_FORM={form}\nSMOKE_FIELD={'nachricht'}")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("seed", "run"):
        raise SystemExit("usage: docker-smoke-flow.py seed|run WORKDIR")
    {"seed": seed, "run": run}[sys.argv[1]](sys.argv[2])
