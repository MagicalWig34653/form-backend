-- Ungeprüfter Bestandsupgrade-Kandidat; nicht automatisch ausführen.
-- Only ciphertext hashes, never plaintext or private keys.
ALTER TABLE migration_jobs
 ADD COLUMN probe_hash CHAR(64) NULL,
 ADD COLUMN test_hash CHAR(64) NULL;
