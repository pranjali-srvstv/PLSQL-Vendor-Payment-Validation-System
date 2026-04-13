
DROP TABLE XX_FIN_STG PURGE;
 
CREATE TABLE XX_FIN_STG
(
  -- Primary Identifier
  RECORD_ID           NUMBER          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 
  -- Source System Reference Fields
  SOURCE_SYSTEM       VARCHAR2(50)    NOT NULL,          -- e.g., 'LEGACY_AR', 'SFDC'
  BATCH_ID            VARCHAR2(30)    NOT NULL,          -- Groups records per run
  TRANSACTION_REF     VARCHAR2(50)    NOT NULL,          -- Unique ref from source
 
  -- Vendor & Financial Data
  VENDOR_ID           NUMBER          NOT NULL,          -- FK to XX_VENDORS_MASTER
  VENDOR_NAME         VARCHAR2(240),                     -- Denormalized for audit
  INVOICE_NUMBER      VARCHAR2(50),
  INVOICE_DATE        DATE,
  AMOUNT              NUMBER(18, 2)   NOT NULL,          -- Transaction amount
  CURRENCY_CODE       VARCHAR2(15)    DEFAULT 'USD',
 
  -- Interface Processing Control Columns (Oracle EBS Standard Pattern)
  PROCESS_STATUS      VARCHAR2(20)    DEFAULT 'PENDING', -- PENDING | SUCCESS | ERROR
  ERROR_MESSAGE       VARCHAR2(2000),                    -- Populated on failure
  PROCESSED_DATE      DATE,                              -- When this record was handled
  CREATED_BY          NUMBER          DEFAULT -1,
  CREATION_DATE       DATE            DEFAULT SYSDATE,
  LAST_UPDATED_BY     NUMBER          DEFAULT -1,
  LAST_UPDATE_DATE    DATE            DEFAULT SYSDATE
);
 
COMMENT ON TABLE  XX_FIN_STG                  IS 'Custom staging table for Financial Reconciliation Interface. Holds raw inbound transactions pending validation.';
COMMENT ON COLUMN XX_FIN_STG.PROCESS_STATUS   IS 'Processing status: PENDING (default), SUCCESS (validated & posted), ERROR (failed validation).';
COMMENT ON COLUMN XX_FIN_STG.BATCH_ID         IS 'Logical grouping key for each interface run. Used for reporting and reprocessing.';
 
 
-- -----------------------------------------------------------------------------
-- 1B. ERROR LOG TABLE: XX_ERROR_LOG
--     Purpose : Centralised error repository for all custom interface programs.
--               Follows a generic, reusable pattern so multiple interfaces
--               can log to the same table (identified by PROGRAM_NAME).
-- -----------------------------------------------------------------------------
 
DROP TABLE XX_ERROR_LOG PURGE;
 
CREATE TABLE XX_ERROR_LOG
(
  -- Primary Identifier
  LOG_ID              NUMBER          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 
  -- Source Identification
  PROGRAM_NAME        VARCHAR2(100)   NOT NULL,    -- Which package/procedure logged this
  BATCH_ID            VARCHAR2(30),                -- Links back to the staging batch
  RECORD_ID           NUMBER,                      -- Links back to XX_FIN_STG.RECORD_ID
  TRANSACTION_REF     VARCHAR2(50),                -- For easy triage without a JOIN
 
  -- Error Detail
  ERROR_TYPE          VARCHAR2(50),                -- e.g., 'VALIDATION', 'SYSTEM', 'DATA'
  ERROR_CODE          VARCHAR2(50),                -- e.g., 'NEG_AMOUNT', 'VENDOR_NF'
  ERROR_MESSAGE       VARCHAR2(4000),              -- Full error description
  ORACLE_ERROR        VARCHAR2(4000),              -- SQLERRM for unexpected errors
 
  -- Audit
  LOG_DATE            DATE            DEFAULT SYSDATE,
  CREATED_BY          NUMBER          DEFAULT -1
);
 
COMMENT ON TABLE  XX_ERROR_LOG               IS 'Centralised error log for all XX_ custom interface programs. Generic design supports multiple programs.';
COMMENT ON COLUMN XX_ERROR_LOG.ERROR_TYPE    IS 'Classifies error: VALIDATION (business rule fail), DATA (bad input data), SYSTEM (unexpected Oracle error).';
COMMENT ON COLUMN XX_ERROR_LOG.ERROR_CODE    IS 'Short, queryable code for error dashboards. e.g. NEG_AMOUNT, VENDOR_NF, NULL_FIELD.';
 
 
-- -----------------------------------------------------------------------------
-- 1C. MOCK MASTER TABLE: XX_VENDORS_MASTER
--     Purpose : Simulates the Oracle EBS AP_SUPPLIERS (formerly PO_VENDORS)
--               master data table for vendor validation in this portfolio demo.
--               In a real EBS environment, validation would query AP_SUPPLIERS
--               directly and check VENDOR_TYPE, ENABLED_FLAG, END_DATE_ACTIVE.
-- -----------------------------------------------------------------------------
 
DROP TABLE XX_VENDORS_MASTER PURGE;
 
CREATE TABLE XX_VENDORS_MASTER
(
  VENDOR_ID           NUMBER          PRIMARY KEY,
  VENDOR_NAME         VARCHAR2(240)   NOT NULL,
  VENDOR_TYPE         VARCHAR2(30),                -- e.g., 'SUPPLIER', 'EMPLOYEE'
  TAX_ID              VARCHAR2(30),
  ENABLED_FLAG        VARCHAR2(1)     DEFAULT 'Y', -- Y = Active, N = Inactive
  CREATION_DATE       DATE            DEFAULT SYSDATE,
  LAST_UPDATE_DATE    DATE            DEFAULT SYSDATE
);
 
COMMENT ON TABLE  XX_VENDORS_MASTER              IS 'Mock vendor master table. Simulates AP_SUPPLIERS for portfolio demonstration purposes.';
COMMENT ON COLUMN XX_VENDORS_MASTER.ENABLED_FLAG IS 'Y = Active vendor eligible for payment. N = Inactive/Blocked vendor - transactions should be rejected.';
 
-- Seed with sample master data
INSERT INTO XX_VENDORS_MASTER (VENDOR_ID, VENDOR_NAME, VENDOR_TYPE, TAX_ID, ENABLED_FLAG)
VALUES (1001, 'Accenture Federal Services LLC', 'SUPPLIER', '52-1234567', 'Y');
 
INSERT INTO XX_VENDORS_MASTER (VENDOR_ID, VENDOR_NAME, VENDOR_TYPE, TAX_ID, ENABLED_FLAG)
VALUES (1002, 'IBM Global Services', 'SUPPLIER', '13-0871985', 'Y');
 
INSERT INTO XX_VENDORS_MASTER (VENDOR_ID, VENDOR_NAME, VENDOR_TYPE, TAX_ID, ENABLED_FLAG)
VALUES (1003, 'Legacy Vendor Corp (Inactive)', 'SUPPLIER', '99-9999999', 'N');
 
INSERT INTO XX_VENDORS_MASTER (VENDOR_ID, VENDOR_NAME, VENDOR_TYPE, TAX_ID, ENABLED_FLAG)
VALUES (1004, 'Deloitte Consulting LLP', 'SUPPLIER', '06-1454765', 'Y');
 
COMMIT;
 
-- Seed staging table with a mix of VALID, INVALID, and edge-case records
INSERT INTO XX_FIN_STG (SOURCE_SYSTEM, BATCH_ID, TRANSACTION_REF, VENDOR_ID, VENDOR_NAME, INVOICE_NUMBER, INVOICE_DATE, AMOUNT, CURRENCY_CODE)
VALUES ('LEGACY_AP', 'BATCH-2026-001', 'TXN-10001', 1001, 'Accenture Federal Services LLC', 'INV-ACC-5521', DATE '2026-03-15', 15750.00, 'USD');
 
INSERT INTO XX_FIN_STG (SOURCE_SYSTEM, BATCH_ID, TRANSACTION_REF, VENDOR_ID, VENDOR_NAME, INVOICE_NUMBER, INVOICE_DATE, AMOUNT, CURRENCY_CODE)
VALUES ('LEGACY_AP', 'BATCH-2026-001', 'TXN-10002', 1002, 'IBM Global Services', 'INV-IBM-8830', DATE '2026-03-18', 42000.50, 'USD');
 
INSERT INTO XX_FIN_STG (SOURCE_SYSTEM, BATCH_ID, TRANSACTION_REF, VENDOR_ID, VENDOR_NAME, INVOICE_NUMBER, INVOICE_DATE, AMOUNT, CURRENCY_CODE)
VALUES ('LEGACY_AP', 'BATCH-2026-001', 'TXN-10003', 1004, 'Deloitte Consulting LLP', 'INV-DLT-0091', DATE '2026-03-20', 88500.00, 'USD');
 
-- ERROR CASE 1: Negative amount
INSERT INTO XX_FIN_STG (SOURCE_SYSTEM, BATCH_ID, TRANSACTION_REF, VENDOR_ID, VENDOR_NAME, INVOICE_NUMBER, INVOICE_DATE, AMOUNT, CURRENCY_CODE)
VALUES ('LEGACY_AP', 'BATCH-2026-001', 'TXN-10004', 1001, 'Accenture Federal Services LLC', 'INV-ACC-5522', DATE '2026-03-21', -500.00, 'USD');
 
-- ERROR CASE 2: Vendor does not exist in master
INSERT INTO XX_FIN_STG (SOURCE_SYSTEM, BATCH_ID, TRANSACTION_REF, VENDOR_ID, VENDOR_NAME, INVOICE_NUMBER, INVOICE_DATE, AMOUNT, CURRENCY_CODE)
VALUES ('LEGACY_AP', 'BATCH-2026-001', 'TXN-10005', 9999, 'Unknown Ghost Vendor', 'INV-UNK-0001', DATE '2026-03-22', 3200.00, 'USD');
 
-- ERROR CASE 3: Inactive vendor
INSERT INTO XX_FIN_STG (SOURCE_SYSTEM, BATCH_ID, TRANSACTION_REF, VENDOR_ID, VENDOR_NAME, INVOICE_NUMBER, INVOICE_DATE, AMOUNT, CURRENCY_CODE)
VALUES ('LEGACY_AP', 'BATCH-2026-001', 'TXN-10006', 1003, 'Legacy Vendor Corp (Inactive)', 'INV-LGC-7712', DATE '2026-03-22', 12000.00, 'USD');
 
-- ERROR CASE 4: Zero amount (edge case, caught by validation)
INSERT INTO XX_FIN_STG (SOURCE_SYSTEM, BATCH_ID, TRANSACTION_REF, VENDOR_ID, VENDOR_NAME, INVOICE_NUMBER, INVOICE_DATE, AMOUNT, CURRENCY_CODE)
VALUES ('LEGACY_AP', 'BATCH-2026-001', 'TXN-10007', 1002, 'IBM Global Services', 'INV-IBM-8831', DATE '2026-03-23', 0.00, 'USD');
 
COMMIT;