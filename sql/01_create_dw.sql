/* ==========================================================
   01_create_dw.sql
   Creates the schemas and all staging + dw tables.
 */
USE Customer360_DW;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'source') EXEC('CREATE SCHEMA source');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'stg')    EXEC('CREATE SCHEMA stg');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'dw')     EXEC('CREATE SCHEMA dw');
GO

/* ---------------- STAGING TABLES ---------------- */

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'client' AND schema_id = SCHEMA_ID('stg'))
CREATE TABLE stg.client (
    client_number        VARCHAR(20)  NOT NULL PRIMARY KEY,
    first_name           VARCHAR(100) NULL,
    last_name            VARCHAR(100) NULL,
    email                VARCHAR(200) NULL,
    email_status         VARCHAR(10)  NOT NULL,   
    mobile_e164          VARCHAR(15)  NULL,      
    date_of_birth        DATE         NULL,
    gender               VARCHAR(10)  NOT NULL,   
    province             VARCHAR(100) NULL,
    city                 VARCHAR(100) NULL,
    signup_date          DATE         NOT NULL,
    duplicate_email_flag BIT          NOT NULL DEFAULT 0
);

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'enrollment' AND schema_id = SCHEMA_ID('stg'))
CREATE TABLE stg.enrollment (
    account_number  VARCHAR(20) NOT NULL PRIMARY KEY,
    client_number   VARCHAR(20) NOT NULL,
    product_type    VARCHAR(50) NOT NULL,
    account_status  VARCHAR(20) NOT NULL,
    enrollment_date DATE        NOT NULL,
    credit_limit    DECIMAL(18,2) NULL,
    loan_amount     DECIMAL(18,2) NULL,
    account_balance DECIMAL(18,2) NULL
);

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'interaction' AND schema_id = SCHEMA_ID('stg'))
CREATE TABLE stg.interaction (
    client_number    VARCHAR(20) NOT NULL,
    event_date       DATE        NOT NULL,
    channel          VARCHAR(50) NOT NULL,
    interaction_type VARCHAR(50) NOT NULL,
    resolved_flag    CHAR(1)     NOT NULL        
);

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'txn' AND schema_id = SCHEMA_ID('stg'))
CREATE TABLE stg.txn (
    client_number    VARCHAR(20) NOT NULL,
    account_number   VARCHAR(20) NOT NULL,
    product_type     VARCHAR(50) NULL,
    event_date       DATE        NOT NULL,
    channel          VARCHAR(50) NOT NULL,
    transaction_type VARCHAR(50) NOT NULL,
    amount           DECIMAL(18,2) NOT NULL
);
GO

/* ---------------- DIMENSIONS ---------------- */

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'dim_date' AND schema_id = SCHEMA_ID('dw'))
CREATE TABLE dw.dim_date (
    date_key     INT         NOT NULL PRIMARY KEY,  
    full_date    DATE        NOT NULL,
    [year]       SMALLINT    NOT NULL,
    [quarter]    TINYINT     NOT NULL,
    month_num    TINYINT     NOT NULL,
    month_name   VARCHAR(12) NOT NULL,
    year_month   CHAR(7)     NOT NULL,              
    month_start  DATE        NOT NULL,
    day_of_month TINYINT     NOT NULL,
    day_name     VARCHAR(12) NOT NULL,
    is_weekend   BIT         NOT NULL
);

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'dim_client' AND schema_id = SCHEMA_ID('dw'))
CREATE TABLE dw.dim_client (
    client_key           INT IDENTITY(1,1) PRIMARY KEY,
    client_number        VARCHAR(20)  NOT NULL UNIQUE,
    first_name           VARCHAR(100) NULL,
    last_name            VARCHAR(100) NULL,
    email                VARCHAR(200) NULL,
    email_status         VARCHAR(10)  NOT NULL,
    mobile_e164          VARCHAR(15)  NULL,
    date_of_birth        DATE         NULL,
    gender               VARCHAR(10)  NOT NULL,
    province             VARCHAR(100) NULL,
    city                 VARCHAR(100) NULL,
    signup_date          DATE         NOT NULL,
    signup_date_key      INT          NOT NULL REFERENCES dw.dim_date(date_key),
    duplicate_email_flag BIT          NOT NULL DEFAULT 0
);

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'dim_product' AND schema_id = SCHEMA_ID('dw'))
CREATE TABLE dw.dim_product (
    product_key  INT IDENTITY(1,1) PRIMARY KEY,
    product_type VARCHAR(50) NOT NULL UNIQUE
);

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'dim_account' AND schema_id = SCHEMA_ID('dw'))
CREATE TABLE dw.dim_account (
    account_key    INT IDENTITY(1,1) PRIMARY KEY,
    account_number VARCHAR(20) NOT NULL UNIQUE,
    account_status VARCHAR(20) NOT NULL,
    is_inferred    BIT NOT NULL DEFAULT 0   -- 1 = account only seen in transactions, never enrolled
);

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'dim_channel' AND schema_id = SCHEMA_ID('dw'))
CREATE TABLE dw.dim_channel (
    channel_key  INT IDENTITY(1,1) PRIMARY KEY,
    channel_name VARCHAR(50) NOT NULL UNIQUE
);

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'dim_interaction_type' AND schema_id = SCHEMA_ID('dw'))
CREATE TABLE dw.dim_interaction_type (
    interaction_type_key INT IDENTITY(1,1) PRIMARY KEY,
    interaction_type     VARCHAR(50) NOT NULL UNIQUE
);

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'dim_transaction_type' AND schema_id = SCHEMA_ID('dw'))
CREATE TABLE dw.dim_transaction_type (
    transaction_type_key INT IDENTITY(1,1) PRIMARY KEY,
    transaction_type     VARCHAR(50) NOT NULL UNIQUE,
    cash_flow            VARCHAR(10) NOT NULL    -- Credit = money in, Debit = money out
);
GO

/* ---------------- FACT TABLES ---------------- */

-- one row per transaction
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'fact_transaction' AND schema_id = SCHEMA_ID('dw'))
CREATE TABLE dw.fact_transaction (
    transaction_key      BIGINT IDENTITY(1,1) PRIMARY KEY,
    client_key           INT NOT NULL REFERENCES dw.dim_client(client_key),
    account_key          INT NOT NULL REFERENCES dw.dim_account(account_key),
    product_key          INT NOT NULL REFERENCES dw.dim_product(product_key),
    date_key             INT NOT NULL REFERENCES dw.dim_date(date_key),
    channel_key          INT NOT NULL REFERENCES dw.dim_channel(channel_key),
    transaction_type_key INT NOT NULL REFERENCES dw.dim_transaction_type(transaction_type_key),
    amount               DECIMAL(18,2) NOT NULL,      -- signed: money out is negative (as in the file)
    amount_abs AS ABS(amount) PERSISTED               -- "transaction value" = size of the amount
);

-- one row per CRM interaction
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'fact_interaction' AND schema_id = SCHEMA_ID('dw'))
CREATE TABLE dw.fact_interaction (
    interaction_key      BIGINT IDENTITY(1,1) PRIMARY KEY,
    client_key           INT NOT NULL REFERENCES dw.dim_client(client_key),
    date_key             INT NOT NULL REFERENCES dw.dim_date(date_key),
    channel_key          INT NOT NULL REFERENCES dw.dim_channel(channel_key),
    interaction_type_key INT NOT NULL REFERENCES dw.dim_interaction_type(interaction_type_key),
    resolved_flag        CHAR(1) NOT NULL              -- Y / N / U (unknown)
);

-- one row per account
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'fact_account' AND schema_id = SCHEMA_ID('dw'))
CREATE TABLE dw.fact_account (
    account_fact_key    INT IDENTITY(1,1) PRIMARY KEY,
    account_key         INT NOT NULL UNIQUE REFERENCES dw.dim_account(account_key),
    client_key          INT NOT NULL REFERENCES dw.dim_client(client_key),
    product_key         INT NOT NULL REFERENCES dw.dim_product(product_key),
    enrollment_date_key INT NOT NULL REFERENCES dw.dim_date(date_key),
    credit_limit        DECIMAL(18,2) NULL,
    loan_amount         DECIMAL(18,2) NULL,
    account_balance     DECIMAL(18,2) NULL
);
GO

 
CREATE OR ALTER VIEW dw.vw_ref AS
SELECT
    (SELECT MAX(d.full_date) FROM dw.fact_transaction f
       JOIN dw.dim_date d ON d.date_key = f.date_key)          AS latest_txn_date,
    (SELECT MAX(x) FROM (
        SELECT MAX(d.full_date) AS x FROM dw.fact_transaction f JOIN dw.dim_date d ON d.date_key = f.date_key
        UNION ALL
        SELECT MAX(d.full_date) FROM dw.fact_interaction f JOIN dw.dim_date d ON d.date_key = f.date_key
        UNION ALL
        SELECT MAX(d.full_date) FROM dw.fact_account f JOIN dw.dim_date d ON d.date_key = f.enrollment_date_key
     ) u)                                                      AS latest_event_date,
    (SELECT MAX(signup_date) FROM dw.dim_client)               AS latest_signup_date;
GO
