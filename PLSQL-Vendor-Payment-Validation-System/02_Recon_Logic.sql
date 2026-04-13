CREATE OR REPLACE PACKAGE XX_FIN_RECON_PKG
AUTHID CURRENT_USER
AS
 
  -- -------------------------------------------------------------------------
  -- Package-level constants for process status codes.
  -- Using constants instead of hardcoded strings prevents typos and makes
  -- global changes (e.g., renaming 'SUCCESS' to 'PROCESSED') trivial.
  -- -------------------------------------------------------------------------
  C_STATUS_PENDING    CONSTANT VARCHAR2(20) := 'PENDING';
  C_STATUS_SUCCESS    CONSTANT VARCHAR2(20) := 'SUCCESS';
  C_STATUS_ERROR      CONSTANT VARCHAR2(20) := 'ERROR';
 
  C_PROGRAM_NAME      CONSTANT VARCHAR2(100) := 'XX_FIN_RECON_PKG';
 
  -- -------------------------------------------------------------------------
  -- PROCEDURE: PROCESS_TRANSACTIONS
  --   The main public procedure. Called by the Oracle EBS Concurrent Manager
  --   (or manually during testing) to process all PENDING records for a given
  --   batch.
  --
  -- Parameters:
  --   p_batch_id    IN  : The batch identifier to process (from XX_FIN_STG)
  --   p_processed   OUT : Count of records successfully processed
  --   p_errored     OUT : Count of records that failed validation
  --   p_return_status OUT: 'S' = Success, 'E' = Error, 'W' = Warning
  -- -------------------------------------------------------------------------
  PROCEDURE PROCESS_TRANSACTIONS
  (
    p_batch_id        IN  VARCHAR2,
    p_processed       OUT NUMBER,
    p_errored         OUT NUMBER,
    p_return_status   OUT VARCHAR2
  );
 
END XX_FIN_RECON_PKG;
/
 
SHOW ERRORS PACKAGE XX_FIN_RECON_PKG;
 
 
-- -----------------------------------------------------------------------------
-- 2B. PACKAGE BODY
--     Contains all implementation logic, including private helper procedures
--     not visible in the spec.
-- -----------------------------------------------------------------------------
 
CREATE OR REPLACE PACKAGE BODY XX_FIN_RECON_PKG
AS
 
  -- ===========================================================================
  -- PRIVATE PROCEDURE: LOG_ERROR
  --   An internal helper that writes a structured record to XX_ERROR_LOG.
  --   Being private means it can only be called within this package body,
  --   keeping the logging implementation encapsulated and consistent.
  --
  --   Uses PRAGMA AUTONOMOUS_TRANSACTION so that error log commits do NOT
  --   depend on the parent transaction. This is critical: even if the main
  --   procedure rolls back, error records are preserved for diagnostics.
  -- ===========================================================================
  PROCEDURE LOG_ERROR
  (
    p_batch_id        IN VARCHAR2,
    p_record_id       IN NUMBER,
    p_transaction_ref IN VARCHAR2,
    p_error_type      IN VARCHAR2,
    p_error_code      IN VARCHAR2,
    p_error_message   IN VARCHAR2,
    p_oracle_error    IN VARCHAR2 DEFAULT NULL
  )
  IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO XX_ERROR_LOG
    (
      PROGRAM_NAME,
      BATCH_ID,
      RECORD_ID,
      TRANSACTION_REF,
      ERROR_TYPE,
      ERROR_CODE,
      ERROR_MESSAGE,
      ORACLE_ERROR,
      LOG_DATE,
      CREATED_BY
    )
    VALUES
    (
      C_PROGRAM_NAME,
      p_batch_id,
      p_record_id,
      p_transaction_ref,
      p_error_type,
      p_error_code,
      p_error_message,
      p_oracle_error,
      SYSDATE,
      -1        -- In EBS, use FND_GLOBAL.USER_ID here
    );
 
    COMMIT; -- Autonomous transaction commit — independent of the caller's session
 
  EXCEPTION
    WHEN OTHERS THEN
      -- If logging itself fails, rollback the autonomous transaction silently.
      -- In a production system, you might write to UTL_FILE or DBMS_OUTPUT
      -- as a last-resort fallback.
      ROLLBACK;
  END LOG_ERROR;
 
 
  -- ===========================================================================
  -- PRIVATE FUNCTION: VALIDATE_VENDOR
  --   Checks whether a vendor exists in XX_VENDORS_MASTER AND is active.
  --   Separating validation into a dedicated function promotes reusability
  --   (other packages can call the same logic) and keeps PROCESS_TRANSACTIONS
  --   clean and readable.
  --
  --   Returns:
  --     'Y'  = Vendor is valid and active
  --     'N'  = Vendor not found
  --     'I'  = Vendor found but inactive/disabled
  -- ===========================================================================
  FUNCTION VALIDATE_VENDOR
  (
    p_vendor_id IN NUMBER
  )
  RETURN VARCHAR2
  IS
    l_enabled_flag  XX_VENDORS_MASTER.ENABLED_FLAG%TYPE;
  BEGIN
    -- Attempt to fetch the vendor's enabled flag from master
    SELECT ENABLED_FLAG
    INTO   l_enabled_flag
    FROM   XX_VENDORS_MASTER
    WHERE  VENDOR_ID = p_vendor_id;
 
    -- Vendor found — now check if they are active
    IF l_enabled_flag = 'Y' THEN
      RETURN 'Y'; -- Valid and active
    ELSE
      RETURN 'I'; -- Found but inactive
    END IF;
 
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      -- Vendor ID does not exist in master data at all
      RETURN 'N';
  END VALIDATE_VENDOR;
 
 
  -- ===========================================================================
  -- PUBLIC PROCEDURE: PROCESS_TRANSACTIONS
  --   Core orchestration procedure. Fetches all PENDING records for the given
  --   batch, applies business validation rules via a cursor loop, and updates
  --   each record with SUCCESS or ERROR status.
  --
  --   Processing Logic (per record):
  --     Step 1 - Validate: Amount must be greater than zero
  --     Step 2 - Validate: Vendor must exist in master (VALIDATE_VENDOR)
  --     Step 3 - Validate: Vendor must be active (ENABLED_FLAG = 'Y')
  --     Step 4 - On all validations pass: mark SUCCESS
  --     Step 5 - On any failure: mark ERROR, log to XX_ERROR_LOG
  --     Step 6 - Unexpected exceptions: caught by WHEN OTHERS, logged as SYSTEM error
  -- ===========================================================================
  PROCEDURE PROCESS_TRANSACTIONS
  (
    p_batch_id        IN  VARCHAR2,
    p_processed       OUT NUMBER,
    p_errored         OUT NUMBER,
    p_return_status   OUT VARCHAR2
  )
  IS
    -- -----------------------------------------------------------------------
    -- CURSOR DEFINITION
    --   Fetches only PENDING records for the target batch.
    --   Using FOR UPDATE SKIP LOCKED is an EBS best-practice for concurrent
    --   processing — if two jobs run simultaneously, each locks its own rows
    --   without waiting, preventing deadlocks.
    -- -----------------------------------------------------------------------
    CURSOR c_pending_txns IS
      SELECT
        RECORD_ID,
        SOURCE_SYSTEM,
        BATCH_ID,
        TRANSACTION_REF,
        VENDOR_ID,
        VENDOR_NAME,
        INVOICE_NUMBER,
        INVOICE_DATE,
        AMOUNT,
        CURRENCY_CODE
      FROM   XX_FIN_STG
      WHERE  BATCH_ID      = p_batch_id
      AND    PROCESS_STATUS = C_STATUS_PENDING
      FOR UPDATE OF PROCESS_STATUS SKIP LOCKED;
 
    -- -----------------------------------------------------------------------
    -- LOCAL VARIABLE DECLARATIONS
    -- Using %TYPE anchoring ties variable data types to their source columns.
    -- If a column type changes (e.g., VARCHAR2(50) to VARCHAR2(100)), these
    -- variables automatically inherit the new type without code changes.
    -- -----------------------------------------------------------------------
    l_vendor_status   VARCHAR2(1);
    l_error_message   XX_FIN_STG.ERROR_MESSAGE%TYPE;
    l_has_error       BOOLEAN;
 
    -- Counters for the OUT parameters
    l_success_count   NUMBER := 0;
    l_error_count     NUMBER := 0;
 
  BEGIN
    -- -----------------------------------------------------------------------
    -- Initialise OUT parameters to safe defaults before any processing
    -- -----------------------------------------------------------------------
    p_processed     := 0;
    p_errored       := 0;
    p_return_status := 'S';
 
    DBMS_OUTPUT.PUT_LINE('=================================================');
    DBMS_OUTPUT.PUT_LINE(' XX_FIN_RECON_PKG.PROCESS_TRANSACTIONS');
    DBMS_OUTPUT.PUT_LINE(' Batch ID    : ' || p_batch_id);
    DBMS_OUTPUT.PUT_LINE(' Start Time  : ' || TO_CHAR(SYSDATE, 'DD-MON-YYYY HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE('=================================================');
 
    -- -----------------------------------------------------------------------
    -- MAIN CURSOR LOOP
    --   Oracle's implicit cursor FOR loop handles OPEN, FETCH, and CLOSE
    --   automatically. Each iteration processes one staging record.
    -- -----------------------------------------------------------------------
    FOR r_txn IN c_pending_txns
    LOOP
      -- Reset error state for each new record
      l_has_error     := FALSE;
      l_error_message := NULL;
 
      BEGIN -- Inner BEGIN-END block for per-record exception isolation.
            -- If one record throws an unexpected error, the cursor loop
            -- continues to the next record rather than aborting entirely.
 
        -- =================================================================
        -- VALIDATION RULE 1: Amount must be a positive non-zero value.
        --   A zero or negative invoice amount indicates corrupt source data
        --   or a credit memo that must be processed through a separate flow.
        -- =================================================================
        IF r_txn.AMOUNT <= 0 THEN
          l_has_error     := TRUE;
          l_error_message := 'VALIDATION FAILED: Invoice amount must be greater than zero. '
                          || 'Received amount: ' || TO_CHAR(r_txn.AMOUNT);
 
          -- Log this validation failure to the central error log
          LOG_ERROR
          (
            p_batch_id        => r_txn.BATCH_ID,
            p_record_id       => r_txn.RECORD_ID,
            p_transaction_ref => r_txn.TRANSACTION_REF,
            p_error_type      => 'VALIDATION',
            p_error_code      => 'NEG_ZERO_AMOUNT',
            p_error_message   => l_error_message
          );
 
        END IF;
 
        -- =================================================================
        -- VALIDATION RULE 2 & 3: Vendor existence and active status.
        --   Only run if we haven't already failed Rule 1. Once an error is
        --   found, further validation is skipped for efficiency (fail-fast).
        -- =================================================================
        IF NOT l_has_error THEN
 
          -- Call the private validation function
          l_vendor_status := VALIDATE_VENDOR(r_txn.VENDOR_ID);
 
          IF l_vendor_status = 'N' THEN
            -- Vendor ID not found in master data at all
            l_has_error     := TRUE;
            l_error_message := 'VALIDATION FAILED: Vendor ID ' || r_txn.VENDOR_ID
                            || ' does not exist in XX_VENDORS_MASTER. '
                            || 'Verify source data or create vendor in EBS.';
 
            LOG_ERROR
            (
              p_batch_id        => r_txn.BATCH_ID,
              p_record_id       => r_txn.RECORD_ID,
              p_transaction_ref => r_txn.TRANSACTION_REF,
              p_error_type      => 'VALIDATION',
              p_error_code      => 'VENDOR_NOT_FOUND',
              p_error_message   => l_error_message
            );
 
          ELSIF l_vendor_status = 'I' THEN
            -- Vendor exists but has been disabled/deactivated
            l_has_error     := TRUE;
            l_error_message := 'VALIDATION FAILED: Vendor ID ' || r_txn.VENDOR_ID
                            || ' (' || r_txn.VENDOR_NAME || ') is inactive. '
                            || 'Transactions cannot be posted to an inactive vendor.';
 
            LOG_ERROR
            (
              p_batch_id        => r_txn.BATCH_ID,
              p_record_id       => r_txn.RECORD_ID,
              p_transaction_ref => r_txn.TRANSACTION_REF,
              p_error_type      => 'VALIDATION',
              p_error_code      => 'VENDOR_INACTIVE',
              p_error_message   => l_error_message
            );
 
          END IF;
 
        END IF; -- End Vendor validation block
 
 
        -- =================================================================
        -- STATUS UPDATE
        --   Based on validation outcome, update the staging record.
        --   We use WHERE CURRENT OF c_pending_txns since the cursor was
        --   opened with FOR UPDATE — this is more efficient than a
        --   second lookup by primary key.
        -- =================================================================
        IF l_has_error THEN
          -- Mark the record as ERROR and capture the human-readable reason
          UPDATE XX_FIN_STG
          SET    PROCESS_STATUS    = C_STATUS_ERROR,
                 ERROR_MESSAGE     = l_error_message,
                 PROCESSED_DATE    = SYSDATE,
                 LAST_UPDATE_DATE  = SYSDATE
          WHERE  CURRENT OF c_pending_txns;
 
          l_error_count := l_error_count + 1;
 
          DBMS_OUTPUT.PUT_LINE('  [ERROR]   TXN: ' || r_txn.TRANSACTION_REF
                            || ' | Amount: ' || r_txn.AMOUNT
                            || ' | Reason: ' || SUBSTR(l_error_message, 1, 60) || '...');
        ELSE
          -- All validations passed — mark as SUCCESS
          -- In a real EBS interface, this is where you would INSERT into
          -- AP_INVOICES_INTERFACE or call AP_IMPORT_INVOICES_PKG.IMPORT_INVOICES
          UPDATE XX_FIN_STG
          SET    PROCESS_STATUS    = C_STATUS_SUCCESS,
                 ERROR_MESSAGE     = NULL,
                 PROCESSED_DATE    = SYSDATE,
                 LAST_UPDATE_DATE  = SYSDATE
          WHERE  CURRENT OF c_pending_txns;
 
          l_success_count := l_success_count + 1;
 
          DBMS_OUTPUT.PUT_LINE('  [SUCCESS] TXN: ' || r_txn.TRANSACTION_REF
                            || ' | Vendor: ' || r_txn.VENDOR_NAME
                            || ' | Amount: ' || TO_CHAR(r_txn.AMOUNT, '999,999,990.00'));
        END IF;
 
      EXCEPTION
        -- -------------------------------------------------------------------
        -- INNER EXCEPTION HANDLER: Catches unexpected system-level errors
        -- for a specific record without killing the entire batch.
        -- SQLERRM and SQLCODE provide the Oracle error details.
        -- -------------------------------------------------------------------
        WHEN OTHERS THEN
          l_error_count := l_error_count + 1;
 
          -- Attempt to mark the record as ERROR
          BEGIN
            UPDATE XX_FIN_STG
            SET    PROCESS_STATUS  = C_STATUS_ERROR,
                   ERROR_MESSAGE   = 'SYSTEM ERROR: Unexpected exception. See XX_ERROR_LOG for details.',
                   PROCESSED_DATE  = SYSDATE,
                   LAST_UPDATE_DATE = SYSDATE
            WHERE  CURRENT OF c_pending_txns;
          EXCEPTION
            WHEN OTHERS THEN NULL; -- If even this UPDATE fails, swallow and continue
          END;
 
          -- Log the full Oracle error for debugging
          LOG_ERROR
          (
            p_batch_id        => r_txn.BATCH_ID,
            p_record_id       => r_txn.RECORD_ID,
            p_transaction_ref => r_txn.TRANSACTION_REF,
            p_error_type      => 'SYSTEM',
            p_error_code      => 'ORA-' || TO_CHAR(ABS(SQLCODE)),
            p_error_message   => 'Unexpected system error during processing.',
            p_oracle_error    => SQLERRM
          );
 
          DBMS_OUTPUT.PUT_LINE('  [SYSTEM ERR] TXN: ' || r_txn.TRANSACTION_REF
                            || ' | ORA Error: ' || SQLERRM);
 
      END; -- End per-record exception block
 
    END LOOP; -- End cursor loop
 
    -- -----------------------------------------------------------------------
    -- Commit all the staging table status updates in a single transaction.
    -- Note: XX_ERROR_LOG inserts already committed autonomously above.
    -- -----------------------------------------------------------------------
    COMMIT;
 
    -- Populate OUT parameters for the caller (e.g., Concurrent Manager log)
    p_processed := l_success_count;
    p_errored   := l_error_count;
 
    -- Determine overall return status
    IF l_error_count > 0 AND l_success_count = 0 THEN
      p_return_status := 'E';  -- All records failed
    ELSIF l_error_count > 0 THEN
      p_return_status := 'W';  -- Mixed: some success, some errors
    ELSE
      p_return_status := 'S';  -- All records processed successfully
    END IF;
 
    DBMS_OUTPUT.PUT_LINE('=================================================');
    DBMS_OUTPUT.PUT_LINE(' PROCESSING COMPLETE');
    DBMS_OUTPUT.PUT_LINE(' Records Succeeded : ' || l_success_count);
    DBMS_OUTPUT.PUT_LINE(' Records Errored   : ' || l_error_count);
    DBMS_OUTPUT.PUT_LINE(' Return Status     : ' || p_return_status);
    DBMS_OUTPUT.PUT_LINE(' End Time          : ' || TO_CHAR(SYSDATE, 'DD-MON-YYYY HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE('=================================================');
 
  EXCEPTION
    -- -------------------------------------------------------------------------
    -- OUTER EXCEPTION HANDLER: Catches catastrophic failures (e.g., tablespace
    -- full, connection lost) that prevent the procedure from completing at all.
    -- -------------------------------------------------------------------------
    WHEN OTHERS THEN
      ROLLBACK;
      p_return_status := 'E';
 
      LOG_ERROR
      (
        p_batch_id        => p_batch_id,
        p_record_id       => NULL,
        p_transaction_ref => NULL,
        p_error_type      => 'SYSTEM',
        p_error_code      => 'PROC_FATAL_ERROR',
        p_error_message   => 'Fatal error in PROCESS_TRANSACTIONS. Batch rolled back.',
        p_oracle_error    => SQLERRM
      );
 
      DBMS_OUTPUT.PUT_LINE('[FATAL] Procedure failed: ' || SQLERRM);
      RAISE; -- Re-raise so the Concurrent Manager captures the failure correctly
 
  END PROCESS_TRANSACTIONS;
 
END XX_FIN_RECON_PKG;
/
 
SHOW ERRORS PACKAGE BODY XX_FIN_RECON_PKG;