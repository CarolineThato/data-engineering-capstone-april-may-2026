/* ============================================================
   00_raw_landing.sql   (run once; safe to re-run)
   Raw landing table: EVERY column is VARCHAR on purpose.
   Why: the raw layer must accept whatever the file contains
   (blank strings, "076 453 0989", "+27...", padded emails) so the
   SSIS load never fails on type conversion. Typing/cleaning is done
   in stg.load_staging with TRY_CONVERT, where bad values are
   logged instead of crashing the data flow.
   VARCHAR (not NVARCHAR) also removes the code page 65001 vs 1252
   error. The file is pure ASCII, so nothing is lost.
   ============================================================ */
USE Customer360_DW;
GO
IF SCHEMA_ID('source') IS NULL EXEC('CREATE SCHEMA source');
IF SCHEMA_ID('stg')    IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('dw')     IS NULL EXEC('CREATE SCHEMA dw');
GO
-- NOTE: drops your existing landing table so the column types match.
DROP TABLE IF EXISTS source.customer_activity_extract;
CREATE TABLE source.customer_activity_extract (
    source_row_id    INT IDENTITY(1,1) NOT NULL PRIMARY KEY, -- lineage; do NOT map in SSIS
    client_number    VARCHAR(50)  NULL,
    first_name       VARCHAR(100) NULL,
    last_name        VARCHAR(100) NULL,
    email            VARCHAR(200) NULL,
    mobile_number    VARCHAR(50)  NULL,
    date_of_birth    VARCHAR(50)  NULL,
    gender           VARCHAR(50)  NULL,
    province         VARCHAR(100) NULL,
    city             VARCHAR(100) NULL,
    signup_date      VARCHAR(50)  NULL,
    event_type       VARCHAR(100) NULL,
    event_date       VARCHAR(50)  NULL,
    account_number   VARCHAR(50)  NULL,
    product_type     VARCHAR(100) NULL,
    account_status   VARCHAR(50)  NULL,
    credit_limit     VARCHAR(50)  NULL,
    loan_amount      VARCHAR(50)  NULL,
    account_balance  VARCHAR(50)  NULL,
    channel          VARCHAR(100) NULL,
    interaction_type VARCHAR(100) NULL,
    resolved_flag    VARCHAR(50)  NULL,
    transaction_type VARCHAR(100) NULL,
    amount           VARCHAR(50)  NULL,
    loaded_at        DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
GO
