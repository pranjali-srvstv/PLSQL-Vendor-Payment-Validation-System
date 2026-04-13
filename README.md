# Oracle EBS Financial Reconciliation Interface

## Overview
This project is a high-quality PL/SQL-based interface designed to meet Oracle EBS (Electronic Business Suite) standards. It automates vendor invoice reconciliation.

## Key Technical Features
- **Modular Design:** Uses PL/SQL Packages (Spec and Body).
- **Advanced Logging:** Autonomous transaction-based error logging.
- **Performance:** Cursor-based processing with row-level locking.
- **Reporting:** Integrated SQL queries for business summary reports.

## How to Deploy
1. Run `01_Tables_Setup.sql` to create staging and master tables.
2. Run `02_Recon_Package_Logic.sql` to compile the business logic.
3. Register the procedure as a Concurrent Program in Oracle EBS.
