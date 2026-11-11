-- SPDX-License-Identifier: AGPL-3.0-only
-- Struktur des Altsystems (Baseline db/schema.sql + Migrationen 001-040, ohne Daten): Stand der realen Altquelle.
-- Erzeugt mit mariadb-dump --no-data auf mariadb:lts nach Anwenden von schema.sql und allen Migrationen. Keine Datensaetze.
CREATE TABLE `anfrageIdempotenz` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `formularUUID` uuid NOT NULL,
  `idempotenzSchluessel` varchar(190) NOT NULL,
  `anfrageUUID` uuid NOT NULL,
  `createdAt` int(11) NOT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_anfrageIdempotenz_schluessel` (`formularUUID`,`idempotenzSchluessel`),
  KEY `idx_anfrageIdempotenz_anfrageUUID` (`anfrageUUID`),
  KEY `idx_anfrageIdempotenz_createdAt` (`createdAt`),
  CONSTRAINT `fk_anfrageIdempotenz_anfrage` FOREIGN KEY (`anfrageUUID`) REFERENCES `anfragen` (`UUID`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_anfrageIdempotenz_formular` FOREIGN KEY (`formularUUID`) REFERENCES `formulare` (`UUID`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `anfragen` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `time` int(64) DEFAULT NULL,
  `formularUUID` uuid DEFAULT NULL,
  `sentServer` varchar(255) DEFAULT NULL,
  `data` longtext DEFAULT NULL,
  `file1` longblob DEFAULT NULL,
  `file1Enc` longtext DEFAULT NULL,
  `file1Name` varchar(255) DEFAULT NULL,
  `malwareScanStatus` varchar(32) NOT NULL DEFAULT 'kein_upload',
  `errors` text DEFAULT NULL,
  `mailBody` longtext DEFAULT NULL,
  `mailBodyFiller` longtext DEFAULT NULL,
  `removable` tinyint(1) NOT NULL DEFAULT 1,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_anfragen_uuid` (`UUID`),
  KEY `idx_anfragen_time` (`time`),
  KEY `idx_anfragen_formular_uuid` (`formularUUID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `anfragenLoeschprotokoll` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `deletedAt` timestamp NOT NULL DEFAULT current_timestamp(),
  `deletedByUserUUID` uuid DEFAULT NULL,
  `deletedByUsername` varchar(255) DEFAULT NULL,
  `anfrageUUID` uuid NOT NULL,
  `anfrageZeitpunkt` int(64) DEFAULT NULL,
  `formularUUID` uuid DEFAULT NULL,
  `formularName` varchar(255) DEFAULT NULL,
  `rechtsgrundlage` enum('ART17_LOESCHANTRAG','ART17_WIDERRUF','SONSTIGER_GRUND') NOT NULL,
  `notiz` varchar(500) DEFAULT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_loeschprotokoll_uuid` (`UUID`),
  KEY `idx_loeschprotokoll_anfrage` (`anfrageUUID`),
  KEY `idx_loeschprotokoll_formular` (`formularUUID`),
  KEY `idx_loeschprotokoll_deletedat` (`deletedAt`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `anmeldeProtokoll` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `zeitpunkt` int(11) NOT NULL,
  `userUUID` uuid DEFAULT NULL,
  `weg` enum('passkey','passwort','totp') NOT NULL DEFAULT 'passwort',
  `erfolg` tinyint(1) NOT NULL,
  `clientIP` varchar(64) DEFAULT NULL,
  `grund` varchar(190) DEFAULT NULL,
  PRIMARY KEY (`ID`),
  KEY `idx_anmeldeProtokoll_user_zeit` (`userUUID`,`zeitpunkt`),
  KEY `idx_anmeldeProtokoll_zeit` (`zeitpunkt`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `benutzerEinstellungen` (
  `userUUID` uuid NOT NULL,
  `key` varchar(64) NOT NULL,
  `value` text NOT NULL,
  `modifiedAt` int(11) NOT NULL,
  PRIMARY KEY (`userUUID`,`key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `benutzerPasskey` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `userUUID` uuid NOT NULL,
  `credentialId` varbinary(255) NOT NULL,
  `publicKey` text NOT NULL,
  `signCount` int(10) unsigned NOT NULL DEFAULT 0,
  `bezeichnung` varchar(120) NOT NULL,
  `erstelltAm` int(11) NOT NULL,
  `letzteNutzung` int(11) DEFAULT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_benutzerPasskey_credential` (`credentialId`),
  KEY `idx_benutzerPasskey_user` (`userUUID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `blockList` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `clientIP` varchar(128) NOT NULL,
  `blockedUntil` decimal(16,0) NOT NULL,
  `createdAt` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`ID`),
  KEY `idx_block_list_client_ip_blocked_until` (`clientIP`,`blockedUntil`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `config` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `value` text DEFAULT NULL,
  `manageable` tinyint(1) NOT NULL DEFAULT 1,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_config_name` (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `datenschluessel` (
  `kid` char(16) NOT NULL,
  `publicKey` varbinary(32) NOT NULL,
  `status` enum('aktiv','auslaufend') NOT NULL,
  `erstelltAm` int(11) NOT NULL,
  `erstelltVon` uuid NOT NULL,
  PRIMARY KEY (`kid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `datenschluesselProtokoll` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `zeit` int(11) NOT NULL,
  `userUUID` uuid DEFAULT NULL,
  `aktion` enum('kontoschluessel_angelegt','wrap_hinzugefuegt','wrap_entfernt','datenschluessel_eingerichtet','zugang_erteilt','zugang_entzogen','recovery_abgerufen','umstieg_umgewickelt','rotation_begonnen','rotation_abgeschlossen') NOT NULL,
  `kid` char(16) DEFAULT NULL,
  `betroffenUUID` uuid DEFAULT NULL,
  `anzahl` int(11) DEFAULT NULL,
  PRIMARY KEY (`ID`),
  KEY `idx_datenschluesselProtokoll_zeit` (`zeit`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `datenschluesselRecovery` (
  `kid` char(16) NOT NULL,
  `salt` varbinary(32) NOT NULL,
  `iterationen` int(11) NOT NULL,
  `iv` varbinary(12) NOT NULL,
  `wrap` varbinary(48) NOT NULL,
  `erstelltAm` int(11) NOT NULL,
  PRIMARY KEY (`kid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `datenschluesselUmstiegAusnahme` (
  `anfrageUUID` uuid NOT NULL,
  `grund` varchar(255) NOT NULL,
  `gemeldetVon` uuid DEFAULT NULL,
  `gemeldetAm` int(11) NOT NULL,
  PRIMARY KEY (`anfrageUUID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `datenschluesselZugang` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `kid` char(16) NOT NULL,
  `userUUID` uuid NOT NULL,
  `enc` varbinary(32) NOT NULL,
  `versiegelt` varbinary(48) NOT NULL,
  `erteiltVon` uuid NOT NULL,
  `erteiltAm` int(11) NOT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_datenschluesselZugang` (`kid`,`userUUID`),
  KEY `idx_datenschluesselZugang_user` (`userUUID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `errors` (
  `ID` int(64) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `correlationId` uuid DEFAULT NULL,
  `formUUID` uuid DEFAULT NULL,
  `anfrageUUID` uuid DEFAULT NULL,
  `clientIP` varchar(255) DEFAULT NULL,
  `time` varchar(128) DEFAULT NULL,
  `errorCode` int(8) DEFAULT NULL,
  `errorMsg` text DEFAULT NULL,
  `event` enum('eingang','versand','authentifizierung','ratenbegrenzung','kryptografie','cron','sonstiges') NOT NULL DEFAULT 'sonstiges',
  `operation` enum('datenbankverbindung','feldvalidierung','mail_filler','mail_organisation','anhang','signaturpruefung','ip_sperre','entschluesselung','cron_lauf','sonstiges') NOT NULL DEFAULT 'sonstiges',
  `safeMessage` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`ID`),
  KEY `idx_errors_anfrage_uuid` (`anfrageUUID`),
  KEY `idx_errors_form_uuid` (`formUUID`),
  KEY `idx_errors_time` (`time`),
  KEY `idx_errors_correlationId` (`correlationId`),
  CONSTRAINT `fk_errors_anfrage` FOREIGN KEY (`anfrageUUID`) REFERENCES `anfragen` (`UUID`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `exportProtokoll` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `exportiertAm` timestamp NOT NULL DEFAULT current_timestamp(),
  `exportiertVonUserUUID` uuid DEFAULT NULL,
  `exportiertVonUsername` varchar(255) DEFAULT NULL,
  `formularUUID` uuid DEFAULT NULL,
  `formularName` varchar(255) DEFAULT NULL,
  `format` enum('csv','json') NOT NULL,
  `anzahlAnfragen` int(11) NOT NULL DEFAULT 0,
  `vonDatum` date DEFAULT NULL,
  `bisDatum` date DEFAULT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_exportProtokoll_uuid` (`UUID`),
  KEY `idx_exportProtokoll_formular` (`formularUUID`),
  KEY `idx_exportProtokoll_exportiertam` (`exportiertAm`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `formularFelder` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `formularUUID` uuid NOT NULL,
  `feldName` varchar(190) NOT NULL,
  `typ` enum('text','email','datum','zahl','bool','auswahl','datei') NOT NULL DEFAULT 'text',
  `pflicht` tinyint(1) NOT NULL DEFAULT 1,
  `regel` text DEFAULT NULL,
  `reihenfolge` int(8) NOT NULL DEFAULT 0,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_formularFelder_feld` (`formularUUID`,`feldName`),
  CONSTRAINT `fk_formularFelder_formular` FOREIGN KEY (`formularUUID`) REFERENCES `formulare` (`UUID`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB AUTO_INCREMENT=4 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `formularSchluessel` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `formularUUID` uuid NOT NULL,
  `clientUaSchluessel` varchar(64) NOT NULL,
  `clientUaSchluesselVorherig` varchar(64) DEFAULT NULL,
  `clientUaSchluesselVorherigGueltigBis` int(11) DEFAULT NULL,
  `clientIpSchluessel` varchar(64) NOT NULL,
  `clientIpSchluesselVorherig` varchar(64) DEFAULT NULL,
  `clientIpSchluesselVorherigGueltigBis` int(11) DEFAULT NULL,
  `ed25519OeffentlicherSchluessel` varchar(64) DEFAULT NULL,
  `ed25519OeffentlicherSchluesselVorherig` varchar(64) DEFAULT NULL,
  `ed25519OeffentlicherSchluesselVorherigGueltigBis` int(11) DEFAULT NULL,
  `erzeugtAm` timestamp NOT NULL DEFAULT current_timestamp(),
  `rotiertAm` timestamp NULL DEFAULT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_formularSchluessel_formular` (`formularUUID`),
  CONSTRAINT `fk_formularSchluessel_formular` FOREIGN KEY (`formularUUID`) REFERENCES `formulare` (`UUID`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `formularSchluesselTrefferweg` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `formularUUID` uuid NOT NULL,
  `beobachtungsTag` date NOT NULL,
  `anzahlFormularspezifisch` int(8) unsigned NOT NULL DEFAULT 0,
  `anzahlGlobal` int(8) unsigned NOT NULL DEFAULT 0,
  `anzahlNichtErmittelbar` int(8) unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_formularSchluesselTrefferweg_tag` (`formularUUID`,`beobachtungsTag`),
  CONSTRAINT `fk_formularSchluesselTrefferweg_formular` FOREIGN KEY (`formularUUID`) REFERENCES `formulare` (`UUID`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `formularWebhooks` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `formularUUID` uuid NOT NULL,
  `zielUrl` varchar(2048) NOT NULL,
  `aktiv` tinyint(1) NOT NULL DEFAULT 1,
  `ed25519PrivatSchluessel` varchar(96) NOT NULL,
  `ed25519OeffentlicherSchluessel` varchar(64) NOT NULL,
  `erstelltAm` timestamp NOT NULL DEFAULT current_timestamp(),
  `erstelltVonUserUUID` uuid DEFAULT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_formularWebhooks_uuid` (`UUID`),
  KEY `idx_formularWebhooks_formular` (`formularUUID`),
  CONSTRAINT `fk_formularWebhooks_formular` FOREIGN KEY (`formularUUID`) REFERENCES `formulare` (`UUID`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `formulare` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `name` varchar(255) DEFAULT NULL,
  `domains` text DEFAULT NULL,
  `fromName` varchar(255) DEFAULT NULL,
  `betreff` varchar(255) DEFAULT NULL,
  `betreffToFIller` varchar(255) DEFAULT NULL,
  `toProductionMails` text DEFAULT NULL,
  `toTestingMails` text DEFAULT NULL,
  `modes` text DEFAULT NULL,
  `active` tinyint(1) NOT NULL DEFAULT 0,
  `cloudflareKeys` text DEFAULT NULL,
  `outgoingProductionServer` varchar(255) DEFAULT NULL,
  `outgoingTestingServer` varchar(255) DEFAULT NULL,
  `formularSendMailToFiller` tinyint(1) NOT NULL DEFAULT 0,
  `essentialPostFields` text DEFAULT NULL,
  `mailBodyFiller` text DEFAULT NULL,
  `mailBody` text DEFAULT NULL,
  `besondereKategorien` tinyint(1) NOT NULL DEFAULT 1 COMMENT 'Enthaelt besondere Kategorien personenbezogener Daten nach Art. 9 DSGVO',
  PRIMARY KEY (`ID`),
  UNIQUE KEY `UUID` (`UUID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `hitLogCritical` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `time` varchar(128) NOT NULL,
  `clientIP` varchar(255) DEFAULT NULL,
  `removable` tinyint(1) NOT NULL DEFAULT 0,
  `count` int(32) NOT NULL DEFAULT 1,
  `clientUA` varchar(255) NOT NULL,
  PRIMARY KEY (`ID`),
  KEY `idx_hit_log_critical_client` (`clientIP`,`clientUA`),
  KEY `idx_hit_log_critical_uuid` (`UUID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `hitLogMemory` (
  `ID` int(16) NOT NULL AUTO_INCREMENT,
  `time` decimal(20,4) NOT NULL,
  `clientIP` varchar(45) NOT NULL DEFAULT '',
  PRIMARY KEY (`ID`),
  KEY `idx_hit_log_memory_time` (`time`) USING BTREE,
  KEY `idx_hit_log_memory_client_time` (`clientIP`,`time`) USING BTREE
) ENGINE=MEMORY DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `konfigurationsProtokoll` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `geaendertAm` timestamp NOT NULL DEFAULT current_timestamp(),
  `geaendertVonUserUUID` uuid DEFAULT NULL,
  `geaendertVonUsername` varchar(255) DEFAULT NULL,
  `configName` varchar(255) NOT NULL,
  `aktion` enum('erstellt','geaendert','geloescht') NOT NULL,
  `alterWert` text DEFAULT NULL,
  `neuerWert` text DEFAULT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_konfigurationsProtokoll_uuid` (`UUID`),
  KEY `idx_konfigurationsProtokoll_geaendertam` (`geaendertAm`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `kontoschluessel` (
  `userUUID` uuid NOT NULL,
  `publicKey` varbinary(32) NOT NULL,
  `erstelltAm` int(11) NOT NULL,
  PRIMARY KEY (`userUUID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `kontoschluesselWrap` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `userUUID` uuid NOT NULL,
  `credentialId` varbinary(255) NOT NULL,
  `prfSalt` varbinary(32) NOT NULL,
  `iv` varbinary(12) NOT NULL,
  `wrap` varbinary(48) NOT NULL,
  `erstelltAm` int(11) NOT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_kontoschluesselWrap_credential` (`credentialId`),
  KEY `idx_kontoschluesselWrap_user` (`userUUID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `mailZielVerifikationen` (
  `host` varchar(255) NOT NULL,
  `verifiedAt` int(64) NOT NULL,
  PRIMARY KEY (`host`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `mailZustellung` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `anfrageUUID` uuid NOT NULL,
  `versandArt` varchar(32) NOT NULL DEFAULT '',
  `versandModus` varchar(16) NOT NULL DEFAULT 'testing',
  `transportweg` varchar(16) NOT NULL DEFAULT '',
  `status` enum('ausstehend','inBearbeitung','zugestellt','fehlgeschlagen','aufgegeben') NOT NULL DEFAULT 'ausstehend',
  `versuche` int(8) NOT NULL DEFAULT 0,
  `naechsterVersuch` int(11) NOT NULL DEFAULT 0,
  `letzterFehler` varchar(500) DEFAULT NULL,
  `erstelltAm` int(11) NOT NULL,
  `aktualisiertAm` int(11) NOT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_mailZustellung_vorgang` (`anfrageUUID`,`versandModus`,`versandArt`),
  KEY `idx_mailZustellung_faellig` (`status`,`naechsterVersuch`),
  CONSTRAINT `fk_mailZustellung_anfrage` FOREIGN KEY (`anfrageUUID`) REFERENCES `anfragen` (`UUID`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `mcpOauthClient` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `clientId` varchar(64) NOT NULL,
  `clientName` varchar(120) NOT NULL,
  `redirectUris` text NOT NULL,
  `erstelltAm` timestamp NOT NULL DEFAULT current_timestamp(),
  `zuletztGenutzt` datetime DEFAULT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_mcpOauthClient_uuid` (`UUID`),
  UNIQUE KEY `uq_mcpOauthClient_clientId` (`clientId`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `mcpOauthCode` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `codeHash` char(64) NOT NULL,
  `grantUUID` uuid NOT NULL,
  `clientId` varchar(64) NOT NULL,
  `userUUID` uuid NOT NULL,
  `redirectUri` varchar(512) NOT NULL,
  `codeChallenge` varchar(128) NOT NULL,
  `resource` varchar(512) DEFAULT NULL,
  `scope` varchar(64) NOT NULL,
  `laeuftAbAm` datetime NOT NULL,
  `eingeloestAm` datetime DEFAULT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_mcpOauthCode_hash` (`codeHash`),
  KEY `idx_mcpOauthCode_grant` (`grantUUID`),
  KEY `idx_mcpOauthCode_laeuftab` (`laeuftAbAm`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `mcpOauthGrant` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `clientId` varchar(64) NOT NULL,
  `userUUID` uuid NOT NULL,
  `erstelltAm` timestamp NOT NULL DEFAULT current_timestamp(),
  `laeuftAbAm` datetime NOT NULL,
  `widerrufenAm` datetime DEFAULT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_mcpOauthGrant_uuid` (`UUID`),
  KEY `idx_mcpOauthGrant_user` (`userUUID`),
  KEY `idx_mcpOauthGrant_client` (`clientId`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `mcpOauthRefresh` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `refreshHash` char(64) NOT NULL,
  `grantUUID` uuid NOT NULL,
  `erstelltAm` timestamp NOT NULL DEFAULT current_timestamp(),
  `laeuftAbAm` datetime NOT NULL,
  `ersetztAm` datetime DEFAULT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_mcpOauthRefresh_hash` (`refreshHash`),
  KEY `idx_mcpOauthRefresh_grant` (`grantUUID`),
  KEY `idx_mcpOauthRefresh_laeuftab` (`laeuftAbAm`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `mcpToken` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `userUUID` uuid NOT NULL,
  `label` varchar(120) NOT NULL,
  `tokenHash` char(64) NOT NULL,
  `praefix` varchar(12) NOT NULL,
  `erstelltAm` timestamp NOT NULL DEFAULT current_timestamp(),
  `laeuftAbAm` datetime NOT NULL,
  `zuletztGenutzt` datetime DEFAULT NULL,
  `widerrufenAm` datetime DEFAULT NULL,
  `grantUUID` uuid DEFAULT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_mcpToken_uuid` (`UUID`),
  UNIQUE KEY `uq_mcpToken_hash` (`tokenHash`),
  KEY `idx_mcpToken_user` (`userUUID`),
  KEY `idx_mcpToken_grant` (`grantUUID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `mcpTokenProtokoll` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `zeitpunkt` timestamp NOT NULL DEFAULT current_timestamp(),
  `ereignis` enum('angelegt','widerrufen','aufruf','oauth-freigabe','oauth-token','oauth-widerruf') NOT NULL,
  `userUUID` uuid DEFAULT NULL,
  `tokenUUID` uuid DEFAULT NULL,
  `werkzeug` varchar(64) DEFAULT NULL,
  `zeilen` int(11) DEFAULT NULL,
  `grund` varchar(64) DEFAULT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_mcpTokenProtokoll_uuid` (`UUID`),
  KEY `idx_mcpTokenProtokoll_zeitpunkt` (`zeitpunkt`),
  KEY `idx_mcpTokenProtokoll_user` (`userUUID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `otpAttempts` (
  `UUID` uuid NOT NULL,
  `failedAttempts` int(8) NOT NULL DEFAULT 0,
  `lockedUntil` decimal(16,0) NOT NULL DEFAULT 0,
  `lastAttempt` decimal(16,0) NOT NULL DEFAULT 0,
  PRIMARY KEY (`UUID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `outgoingMailProxy` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `name` varchar(255) NOT NULL,
  `proxyURL` text DEFAULT NULL,
  `proxyAuth` varchar(255) DEFAULT NULL,
  `fromMail` varchar(255) NOT NULL,
  PRIMARY KEY (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `outgoingMailServer` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `name` varchar(255) NOT NULL,
  `SMTPHost` varchar(128) DEFAULT NULL,
  `SMTPPort` varchar(128) DEFAULT NULL,
  `SMTPSecurity` varchar(128) DEFAULT NULL,
  `SMTPUsername` varchar(128) DEFAULT NULL,
  `SMTPPassword` varchar(128) DEFAULT NULL,
  `SMTPallowSelfSigned` tinyint(1) NOT NULL DEFAULT 0,
  `fromMail` varchar(255) NOT NULL,
  PRIMARY KEY (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `statistics` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `timestamp` timestamp NOT NULL DEFAULT current_timestamp(),
  `formularUUID` uuid NOT NULL,
  `status` enum('SUCCESS','CLOUDFLARE_MISSING','CLOUDFLARE_GENERIC','MISSING_FIELDS','SUSPICIOUS','GENERIC_ERROR','UNDEFINED_ERROR','INTERNAL_SERVER_ERROR','AUTHORIZATION_DENIED','DNS_RESOLUTION_FAILED') NOT NULL DEFAULT 'UNDEFINED_ERROR',
  `type` enum('ANFRAGE','VISIT') DEFAULT NULL,
  `gclid` varchar(255) DEFAULT NULL,
  `userAgent` varchar(255) DEFAULT NULL,
  `domain` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`ID`),
  KEY `UUID_formulare_statistics` (`formularUUID`),
  KEY `idx_statistics_timestamp` (`timestamp`),
  KEY `idx_statistics_gclid` (`gclid`),
  CONSTRAINT `UUID_formulare_statistics` FOREIGN KEY (`formularUUID`) REFERENCES `formulare` (`UUID`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `statistikLoeschprotokoll` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `geloeschtAm` timestamp NOT NULL DEFAULT current_timestamp(),
  `geloeschtVonUserUUID` uuid DEFAULT NULL,
  `geloeschtVonUsername` varchar(255) DEFAULT NULL,
  `anzahl` int(11) NOT NULL,
  `statistikUUIDs` text NOT NULL,
  `filter` text NOT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_statistikLoeschprotokoll_uuid` (`UUID`),
  KEY `idx_statistikLoeschprotokoll_geloeschtam` (`geloeschtAm`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `userFormularAccess` (
  `userUUID` uuid NOT NULL,
  `formularUUID` uuid NOT NULL,
  `grantedAt` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`userUUID`,`formularUUID`),
  KEY `idx_userFormularAccess_formularUUID` (`formularUUID`),
  CONSTRAINT `fk_userFormularAccess_formular` FOREIGN KEY (`formularUUID`) REFERENCES `formulare` (`UUID`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_userFormularAccess_user` FOREIGN KEY (`userUUID`) REFERENCES `users` (`UUID`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `users` (
  `DBID` int(5) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `username` varchar(255) NOT NULL,
  `password` varchar(255) NOT NULL,
  `MFAKey` varchar(255) DEFAULT NULL,
  `userType` varchar(255) NOT NULL,
  `aktiv` tinyint(1) NOT NULL DEFAULT 1,
  `erstelltAm` int(11) NOT NULL DEFAULT 0,
  `letzteAnmeldung` int(11) DEFAULT NULL,
  `mcpErlaubt` tinyint(1) NOT NULL DEFAULT 0,
  PRIMARY KEY (`DBID`),
  UNIQUE KEY `uq_users_uuid` (`UUID`),
  UNIQUE KEY `uq_users_username` (`username`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `vertrauenswuerdigeNetze` (
  `ID` int(8) NOT NULL AUTO_INCREMENT,
  `bereich` varchar(64) NOT NULL,
  `bezeichnung` varchar(120) NOT NULL,
  `erstelltAm` int(11) NOT NULL,
  `angelegtVon` uuid DEFAULT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_vertrauenswuerdigeNetze_bereich` (`bereich`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE `webhookOutbox` (
  `ID` int(11) NOT NULL AUTO_INCREMENT,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `webhookUUID` uuid NOT NULL,
  `formularUUID` uuid NOT NULL,
  `anfrageUUID` uuid NOT NULL,
  `eingegangenAm` int(11) NOT NULL,
  `status` enum('offen','erfolgreich','fehlgeschlagen_endgueltig') NOT NULL DEFAULT 'offen',
  `versuche` int(11) NOT NULL DEFAULT 0,
  `naechsterVersuchAm` int(11) NOT NULL,
  `claimToken` varchar(64) DEFAULT NULL,
  `leaseUntil` int(11) DEFAULT NULL,
  `letzterFehler` varchar(255) DEFAULT NULL,
  `createdAt` timestamp NOT NULL DEFAULT current_timestamp(),
  `abgeschlossenAm` timestamp NULL DEFAULT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_webhookOutbox_uuid` (`UUID`),
  KEY `idx_webhookOutbox_versand` (`status`,`naechsterVersuchAm`),
  KEY `idx_webhookOutbox_anfrage` (`anfrageUUID`),
  KEY `fk_webhookOutbox_webhook` (`webhookUUID`),
  KEY `idx_webhookOutbox_claim` (`status`,`naechsterVersuchAm`,`leaseUntil`),
  CONSTRAINT `fk_webhookOutbox_webhook` FOREIGN KEY (`webhookUUID`) REFERENCES `formularWebhooks` (`UUID`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
