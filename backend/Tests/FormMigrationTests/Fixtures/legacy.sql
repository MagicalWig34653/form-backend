-- SPDX-License-Identifier: AGPL-3.0-only

-- Structural fixture: baseline + migrations 008/010/012/014/018/024 (P9 subset). No old INSERTs.

CREATE TABLE `formulare` (
  `ID` int(8) NOT NULL,
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
  `mailBody` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE `anfragen` (
  `ID` int(8) NOT NULL,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `time` int(64) DEFAULT NULL,
  `formularUUID` uuid DEFAULT NULL,
  `sentServer` varchar(255) DEFAULT NULL,
  `data` text DEFAULT NULL,
  `file1` longblob DEFAULT NULL,
  `file1Enc` mediumtext DEFAULT NULL,
  `file1Name` varchar(255) DEFAULT NULL,
  `errors` text DEFAULT NULL,
  `mailBody` text DEFAULT NULL,
  `mailBodyFiller` text DEFAULT NULL,
  `removable` tinyint(1) NOT NULL DEFAULT 1
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE `outgoingMailServer` (
  `ID` int(8) NOT NULL,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `name` varchar(255) NOT NULL,
  `SMTPHost` varchar(128) DEFAULT NULL,
  `SMTPPort` varchar(128) DEFAULT NULL,
  `SMTPSecurity` varchar(128) DEFAULT NULL,
  `SMTPUsername` varchar(128) DEFAULT NULL,
  `SMTPPassword` varchar(128) DEFAULT NULL,
  `SMTPallowSelfSigned` tinyint(1) NOT NULL DEFAULT 0,
  `fromMail` varchar(255) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE `outgoingMailProxy` (
  `ID` int(8) NOT NULL,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `name` varchar(255) NOT NULL,
  `proxyURL` text DEFAULT NULL,
  `proxyAuth` varchar(255) DEFAULT NULL,
  `fromMail` varchar(255) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE `statistics` (
  `ID` int(8) NOT NULL,
  `UUID` uuid NOT NULL DEFAULT uuid(),
  `timestamp` timestamp NOT NULL DEFAULT current_timestamp(),
  `formularUUID` uuid NOT NULL,
  `status` enum('SUCCESS','CLOUDFLARE_MISSING','CLOUDFLARE_GENERIC','MISSING_FIELDS','SUSPICIOUS','GENERIC_ERROR','UNDEFINED_ERROR','INTERNAL_SERVER_ERROR','AUTHORIZATION_DENIED','DNS_RESOLUTION_FAILED') NOT NULL DEFAULT 'UNDEFINED_ERROR',
  `type` enum('ANFRAGE','VISIT') DEFAULT NULL,
  `gclid` varchar(255) DEFAULT NULL,
  `userAgent` varchar(255) DEFAULT NULL,
  `domain` varchar(255) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS `formularFelder` (
    `ID`           int(8) NOT NULL AUTO_INCREMENT,
    `formularUUID` uuid NOT NULL,
    `feldName`     varchar(190) NOT NULL,
    `typ`          enum('text','email','datum','zahl','bool','auswahl','datei') NOT NULL DEFAULT 'text',
    `pflicht`      tinyint(1) NOT NULL DEFAULT 1,
    `regel`        text DEFAULT NULL,
    `reihenfolge`  int(8) NOT NULL DEFAULT 0,
    PRIMARY KEY (`ID`),
    UNIQUE KEY `uq_formularFelder_feld` (`formularUUID`, `feldName`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS `anfrageIdempotenz` (
    `ID`                   int(8) NOT NULL AUTO_INCREMENT,
    `formularUUID`         uuid NOT NULL,
    `idempotenzSchluessel` varchar(190) NOT NULL,
    `anfrageUUID`          uuid NOT NULL,
    `createdAt`            int(11) NOT NULL,
    PRIMARY KEY (`ID`),
    UNIQUE KEY `uq_anfrageIdempotenz_schluessel` (`formularUUID`, `idempotenzSchluessel`),
    KEY `idx_anfrageIdempotenz_anfrageUUID` (`anfrageUUID`),
    KEY `idx_anfrageIdempotenz_createdAt` (`createdAt`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS `formularWebhooks` (
    `ID`                              int(8) NOT NULL AUTO_INCREMENT,
    `UUID`                            uuid NOT NULL DEFAULT uuid(),
    `formularUUID`                    uuid NOT NULL,
    `zielUrl`                         varchar(2048) NOT NULL,
    `aktiv`                           tinyint(1) NOT NULL DEFAULT 1,
    `ed25519PrivatSchluessel`         varchar(96) NOT NULL,
    `ed25519OeffentlicherSchluessel`  varchar(64) NOT NULL,
    `erstelltAm`                      timestamp NOT NULL DEFAULT current_timestamp(),
    `erstelltVonUserUUID`             uuid DEFAULT NULL,
    PRIMARY KEY (`ID`),
    UNIQUE KEY `uq_formularWebhooks_uuid` (`UUID`),
    KEY `idx_formularWebhooks_formular` (`formularUUID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

ALTER TABLE formulare ADD besondereKategorien BOOLEAN NOT NULL DEFAULT 0;

ALTER TABLE anfragen ADD malwareScanStatus VARCHAR(32) NOT NULL DEFAULT 'nicht_geprueft';

ALTER TABLE anfragen MODIFY data LONGTEXT, MODIFY file1Enc LONGTEXT, MODIFY mailBody LONGTEXT, MODIFY mailBodyFiller LONGTEXT;

INSERT INTO formulare (ID,UUID,name,active) VALUES (1,'11111111-1111-4111-8111-111111111111','Synthetisches Formular',1);

INSERT INTO formularFelder (formularUUID,feldName,typ,pflicht,reihenfolge) VALUES ('11111111-1111-4111-8111-111111111111','email','email',1,0);

INSERT INTO anfragen (ID,UUID,formularUUID,time,data,removable) VALUES (1,'22222222-2222-4222-8222-222222222222','11111111-1111-4111-8111-111111111111',1700000000,'unsupported-synthetic-packet',0);

INSERT INTO anfrageIdempotenz (formularUUID,idempotenzSchluessel,anfrageUUID,createdAt) VALUES ('11111111-1111-4111-8111-111111111111','synthetic-retry','22222222-2222-4222-8222-222222222222',1700000000);

CREATE TABLE IF NOT EXISTS `datenschluessel` (
    `kid`         char(16)                   NOT NULL,
    `publicKey`   varbinary(32)              NOT NULL,
    `status`      enum('aktiv','auslaufend') NOT NULL,
    `erstelltAm`  int(11)                    NOT NULL,
    `erstelltVon` uuid                       NOT NULL,
    PRIMARY KEY (`kid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
