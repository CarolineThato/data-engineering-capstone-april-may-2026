/* ============================================================
   01_create_dw.sql  -  staging + dw schema DDL (re-runnable)
   DESIGN DECISIONS
   * Three facts, three grains (the old single "mega fact" mixed
     grains: a balance, a transaction and a CRM contact are different
     events, so NULL-heavy rows and double counting follow):
       fact_transaction : 1 row per transaction
       fact_interaction : 1 row per CRM interaction
       fact_account     : 1 row per account (balance/limit snapshot)
   * Surrogate keys: INT IDENTITY on dimensions; -1 = "Unknown" member
     so no fact ever has a NULL foreign key.
   * dim_date key is yyyymmdd (INT); built, not carried as strings.
   * dim_client is SCD Type 1: the extract is one current snapshot with
     no effective dates, so Type 2 history would be invented.
   * Facts have no source ID, so the idempotency key is row_hash
     (SHA2-256 of the cleaned source row); loads use WHERE NOT EXISTS.
   * Orphan accounts (in transactions, never enrolled) are kept in
     dim_account with is_inferred = 1, not deleted.
   ============================================================ */
USE Customer360_DW;
GO
/* ---------- STAGING ---------- */
IF OBJECT_ID('stg.dq_issue') IS NULL
CREATE TABLE stg.dq_issue(
    issue_id    INT IDENTITY PRIMARY KEY,
    logged_at   DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    rule_name   VARCHAR(60)  NOT NULL,
    severity    VARCHAR(10)  NOT NULL,   -- INFO / WARN
    entity_key  VARCHAR(60)  NULL,
    source_row_id INT        NULL,
    detail      VARCHAR(300) NULL);
IF OBJECT_ID('stg.client') IS NULL
CREATE TABLE stg.client(
    client_number VARCHAR(20) NOT NULL PRIMARY KEY,
    first_name VARCHAR(100), last_name VARCHAR(100),
    email VARCHAR(200) NULL, email_status VARCHAR(10) NOT NULL,   -- Valid/Invalid/Missing
    mobile_e164 VARCHAR(15) NULL,
    date_of_birth DATE NULL, gender VARCHAR(10) NOT NULL,
    province VARCHAR(100), city VARCHAR(100), signup_date DATE NOT NULL,
    duplicate_email_flag BIT NOT NULL);
IF OBJECT_ID('stg.enrollment') IS NULL
CREATE TABLE stg.enrollment(
    account_number VARCHAR(20) NOT NULL PRIMARY KEY, client_number VARCHAR(20) NOT NULL,
    product_type VARCHAR(50) NOT NULL, account_status VARCHAR(20) NOT NULL,
    enrollment_date DATE NOT NULL, credit_limit DECIMAL(18,2) NULL,
    loan_amount DECIMAL(18,2) NULL, account_balance DECIMAL(18,2) NULL, source_row_id INT);
IF OBJECT_ID('stg.interaction') IS NULL
CREATE TABLE stg.interaction(
    row_hash BINARY(32) NOT NULL PRIMARY KEY, client_number VARCHAR(20) NOT NULL,
    event_date DATE NOT NULL, channel VARCHAR(50) NOT NULL, interaction_type VARCHAR(50) NOT NULL,
    resolved_flag CHAR(1) NOT NULL, source_row_id INT);          -- Y / N / U(nknown)
IF OBJECT_ID('stg.txn') IS NULL
CREATE TABLE stg.txn(
    row_hash BINARY(32) NOT NULL PRIMARY KEY, client_number VARCHAR(20) NOT NULL,
    account_number VARCHAR(20) NOT NULL, product_type VARCHAR(50) NULL,
    event_date DATE NOT NULL, channel VARCHAR(50) NOT NULL, transaction_type VARCHAR(50) NOT NULL,
    amount DECIMAL(18,2) NOT NULL, source_row_id INT);
GO
/* ---------- DIMENSIONS ---------- */
IF OBJECT_ID('dw.dim_date') IS NULL
CREATE TABLE dw.dim_date(
    date_key INT NOT NULL PRIMARY KEY, full_date DATE NOT NULL,
    [year] SMALLINT, [quarter] TINYINT, month_num TINYINT, month_name VARCHAR(12),
    year_month CHAR(7), month_start DATE, day_of_month TINYINT,
    day_name VARCHAR(12), is_weekend BIT);
IF OBJECT_ID('dw.dim_client') IS NULL
CREATE TABLE dw.dim_client(
    client_key INT IDENTITY(1,1) PRIMARY KEY, client_number VARCHAR(20) NOT NULL UNIQUE,
    first_name VARCHAR(100), last_name VARCHAR(100),
    email VARCHAR(200) NULL, email_status VARCHAR(10) NOT NULL, mobile_e164 VARCHAR(15) NULL,
    date_of_birth DATE NULL, gender VARCHAR(10) NOT NULL,
    province VARCHAR(100), city VARCHAR(100),
    signup_date DATE NULL, signup_date_key INT NOT NULL REFERENCES dw.dim_date(date_key),
    duplicate_email_flag BIT NOT NULL DEFAULT 0);
IF OBJECT_ID('dw.dim_product') IS NULL
CREATE TABLE dw.dim_product(product_key INT IDENTITY(1,1) PRIMARY KEY, product_type VARCHAR(50) NOT NULL UNIQUE);
IF OBJECT_ID('dw.dim_account') IS NULL
CREATE TABLE dw.dim_account(
    account_key INT IDENTITY(1,1) PRIMARY KEY, account_number VARCHAR(20) NOT NULL UNIQUE,
    account_status VARCHAR(20) NOT NULL, is_inferred BIT NOT NULL DEFAULT 0);
IF OBJECT_ID('dw.dim_channel') IS NULL
CREATE TABLE dw.dim_channel(channel_key INT IDENTITY(1,1) PRIMARY KEY, channel_name VARCHAR(50) NOT NULL UNIQUE);
IF OBJECT_ID('dw.dim_interaction_type') IS NULL
CREATE TABLE dw.dim_interaction_type(interaction_type_key INT IDENTITY(1,1) PRIMARY KEY, interaction_type VARCHAR(50) NOT NULL UNIQUE);
IF OBJECT_ID('dw.dim_transaction_type') IS NULL
CREATE TABLE dw.dim_transaction_type(
    transaction_type_key INT IDENTITY(1,1) PRIMARY KEY, transaction_type VARCHAR(50) NOT NULL UNIQUE,
    cash_flow VARCHAR(10) NOT NULL);   -- Credit = money in, Debit = money out
GO
/* ---------- FACTS ---------- */
IF OBJECT_ID('dw.fact_transaction') IS NULL
CREATE TABLE dw.fact_transaction(
    transaction_key BIGINT IDENTITY(1,1) PRIMARY KEY,
    row_hash BINARY(32) NOT NULL UNIQUE,          -- idempotency key
    source_row_id INT NULL,
    client_key INT NOT NULL REFERENCES dw.dim_client, account_key INT NOT NULL REFERENCES dw.dim_account,
    product_key INT NOT NULL REFERENCES dw.dim_product, date_key INT NOT NULL REFERENCES dw.dim_date,
    channel_key INT NOT NULL REFERENCES dw.dim_channel,
    transaction_type_key INT NOT NULL REFERENCES dw.dim_transaction_type,
    amount DECIMAL(18,2) NOT NULL,                -- signed: outflows negative (as in source)
    amount_abs AS ABS(amount) PERSISTED);         -- "transaction value" = gross
IF OBJECT_ID('dw.fact_interaction') IS NULL
CREATE TABLE dw.fact_interaction(
    interaction_key BIGINT IDENTITY(1,1) PRIMARY KEY, row_hash BINARY(32) NOT NULL UNIQUE,
    source_row_id INT NULL,
    client_key INT NOT NULL REFERENCES dw.dim_client, date_key INT NOT NULL REFERENCES dw.dim_date,
    channel_key INT NOT NULL REFERENCES dw.dim_channel,
    interaction_type_key INT NOT NULL REFERENCES dw.dim_interaction_type,
    resolved_flag CHAR(1) NOT NULL,               -- Y / N / U
    interaction_count AS CAST(1 AS INT));         -- handy additive measure
IF OBJECT_ID('dw.fact_account') IS NULL
CREATE TABLE dw.fact_account(
    account_fact_key INT IDENTITY(1,1) PRIMARY KEY,
    account_key INT NOT NULL UNIQUE REFERENCES dw.dim_account,   -- grain = 1 per account
    client_key INT NOT NULL REFERENCES dw.dim_client, product_key INT NOT NULL REFERENCES dw.dim_product,
    enrollment_date_key INT NOT NULL REFERENCES dw.dim_date,
    credit_limit DECIMAL(18,2) NULL, loan_amount DECIMAL(18,2) NULL,
    account_balance DECIMAL(18,2) NULL);                          -- semi-additive (do not sum over time)
GO
/* ---------- helper view: reference dates for a STATIC extract ---------- */
CREATE OR ALTER VIEW dw.vw_ref AS
SELECT
  (SELECT MAX(d.full_date) FROM dw.fact_transaction f JOIN dw.dim_date d ON d.date_key=f.date_key) AS latest_txn_date,
  (SELECT MAX(x) FROM (SELECT MAX(d.full_date) x FROM dw.fact_transaction f JOIN dw.dim_date d ON d.date_key=f.date_key
        UNION ALL SELECT MAX(d.full_date) FROM dw.fact_interaction f JOIN dw.dim_date d ON d.date_key=f.date_key
        UNION ALL SELECT MAX(d.full_date) FROM dw.fact_account f JOIN dw.dim_date d ON d.date_key=f.enrollment_date_key) u) AS latest_event_date,
  (SELECT MAX(signup_date) FROM dw.dim_client) AS latest_signup_date;
GO
