/* ============================================================
   02_etl_procs.sql
 
   ============================================================ */
USE Customer360_DW;
GO

/* ------------------------------------------------------------
   1. STAGING
   ------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE stg.load_staging
AS
BEGIN
    SET NOCOUNT ON;

    /* ---- checks on the raw table---- */
    IF NOT EXISTS (SELECT 1 FROM source.customer_activity_extract)
        THROW 50001, 'The raw table is empty. Run package 01 first.', 1;

    IF EXISTS (SELECT 1 FROM source.customer_activity_extract
               WHERE event_type IS NULL
                  OR LTRIM(RTRIM(event_type)) NOT IN ('Product Enrollment', 'CRM Interaction', 'Transaction'))
        THROW 50002, 'Found a row with a missing or unknown event_type.', 1;

    IF EXISTS (SELECT 1 FROM source.customer_activity_extract
               WHERE TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(event_date)), ''), 23) IS NULL
                  OR TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(signup_date)), ''), 23) IS NULL)
        THROW 50003, 'Found an event_date or signup_date that is missing or not yyyy-mm-dd.', 1;

    IF EXISTS (SELECT 1 FROM source.customer_activity_extract
               WHERE (NULLIF(LTRIM(RTRIM(amount)), '')          IS NOT NULL AND TRY_CONVERT(DECIMAL(18,2), NULLIF(LTRIM(RTRIM(amount)), ''))          IS NULL)
                  OR (NULLIF(LTRIM(RTRIM(account_balance)), '') IS NOT NULL AND TRY_CONVERT(DECIMAL(18,2), NULLIF(LTRIM(RTRIM(account_balance)), '')) IS NULL)
                  OR (NULLIF(LTRIM(RTRIM(credit_limit)), '')    IS NOT NULL AND TRY_CONVERT(DECIMAL(18,2), NULLIF(LTRIM(RTRIM(credit_limit)), ''))    IS NULL)
                  OR (NULLIF(LTRIM(RTRIM(loan_amount)), '')     IS NOT NULL AND TRY_CONVERT(DECIMAL(18,2), NULLIF(LTRIM(RTRIM(loan_amount)), ''))     IS NULL))
        THROW 50004, 'Found a number (amount, balance, credit limit or loan amount) that is not numeric.', 1;

    /* ---- empty the staging tables so the load can be repeated ---- */
    TRUNCATE TABLE stg.client;
    TRUNCATE TABLE stg.enrollment;
    TRUNCATE TABLE stg.interaction;
    TRUNCATE TABLE stg.txn;

    /* ---- CLIENT: one row per client_number, cleaned ----
        */
    INSERT INTO stg.client
        (client_number, first_name, last_name, email, email_status, mobile_e164,
         date_of_birth, gender, province, city, signup_date, duplicate_email_flag)
    SELECT DISTINCT
        UPPER(LTRIM(RTRIM(r.client_number))),
        NULLIF(LTRIM(RTRIM(r.first_name)), ''),
        NULLIF(LTRIM(RTRIM(r.last_name)), ''),
        LOWER(NULLIF(LTRIM(RTRIM(r.email)), '')),
        CASE WHEN NULLIF(LTRIM(RTRIM(r.email)), '') IS NULL THEN 'Missing'
             WHEN LTRIM(RTRIM(r.email)) LIKE '% %'          THEN 'Invalid'   -- space inside the address
             WHEN LTRIM(RTRIM(r.email)) NOT LIKE '%_@_%._%' THEN 'Invalid'
             ELSE 'Valid' END,
        -- phone: 0821234567 / 27821234567 / +27821234567 all become +27821234567
        CASE WHEN LEFT(p.phone, 1) = '0'  AND LEN(p.phone) = 10 THEN '+27' + SUBSTRING(p.phone, 2, 9)
             WHEN LEFT(p.phone, 2) = '27' AND LEN(p.phone) = 11 THEN '+' + p.phone
             WHEN LEFT(p.phone, 3) = '+27' AND LEN(p.phone) = 12 THEN p.phone
             ELSE NULL END,
        TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(r.date_of_birth)), ''), 23),
        CASE UPPER(LTRIM(RTRIM(r.gender))) WHEN 'M' THEN 'Male' WHEN 'F' THEN 'Female' ELSE 'Unknown' END,
        NULLIF(LTRIM(RTRIM(r.province)), ''),
        NULLIF(LTRIM(RTRIM(r.city)), ''),
        TRY_CONVERT(DATE, LTRIM(RTRIM(r.signup_date)), 23),
        0
    FROM source.customer_activity_extract r
    CROSS APPLY (SELECT REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(r.mobile_number, ''))), ' ', ''), '-', '') AS phone) p;

    -- flag clients who share an email address with a different client
    UPDATE c
    SET duplicate_email_flag = 1
    FROM stg.client c
    WHERE c.email IS NOT NULL
      AND EXISTS (SELECT 1 FROM stg.client o
                  WHERE o.email = c.email AND o.client_number <> c.client_number);

    /* ---- SPLIT BY EVENT TYPE  ---- */

    -- Product Enrollment rows -> stg.enrollment
    INSERT INTO stg.enrollment
        (account_number, client_number, product_type, account_status, enrollment_date,
         credit_limit, loan_amount, account_balance)
    SELECT DISTINCT
        UPPER(LTRIM(RTRIM(account_number))),
        UPPER(LTRIM(RTRIM(client_number))),
        LTRIM(RTRIM(product_type)),
        LTRIM(RTRIM(account_status)),
        TRY_CONVERT(DATE, LTRIM(RTRIM(event_date)), 23),
        TRY_CONVERT(DECIMAL(18,2), NULLIF(LTRIM(RTRIM(credit_limit)), '')),
        TRY_CONVERT(DECIMAL(18,2), NULLIF(LTRIM(RTRIM(loan_amount)), '')),
        TRY_CONVERT(DECIMAL(18,2), NULLIF(LTRIM(RTRIM(account_balance)), ''))
    FROM source.customer_activity_extract
    WHERE LTRIM(RTRIM(event_type)) = 'Product Enrollment';

    -- CRM Interaction rows -> stg.interaction
  
    INSERT INTO stg.interaction (client_number, event_date, channel, interaction_type, resolved_flag)
    SELECT DISTINCT
        UPPER(LTRIM(RTRIM(client_number))),
        TRY_CONVERT(DATE, LTRIM(RTRIM(event_date)), 23),
        LTRIM(RTRIM(channel)),
        LTRIM(RTRIM(interaction_type)),
        CASE WHEN UPPER(LTRIM(RTRIM(resolved_flag))) IN ('Y', 'N')
             THEN UPPER(LTRIM(RTRIM(resolved_flag))) ELSE 'U' END    
    FROM source.customer_activity_extract
    WHERE LTRIM(RTRIM(event_type)) = 'CRM Interaction';

    -- Transaction rows -> stg.txn
    INSERT INTO stg.txn (client_number, account_number, product_type, event_date, channel, transaction_type, amount)
    SELECT DISTINCT
        UPPER(LTRIM(RTRIM(client_number))),
        UPPER(LTRIM(RTRIM(account_number))),
        NULLIF(LTRIM(RTRIM(product_type)), ''),
        TRY_CONVERT(DATE, LTRIM(RTRIM(event_date)), 23),
        LTRIM(RTRIM(channel)),
        LTRIM(RTRIM(transaction_type)),
        TRY_CONVERT(DECIMAL(18,2), LTRIM(RTRIM(amount)))
    FROM source.customer_activity_extract
    WHERE LTRIM(RTRIM(event_type)) = 'Transaction';

    /* ---- show what happened ---- */
    DECLARE @raw INT = (SELECT COUNT(*) FROM source.customer_activity_extract);
    DECLARE @kept INT = (SELECT COUNT(*) FROM stg.enrollment)
                      + (SELECT COUNT(*) FROM stg.interaction)
                      + (SELECT COUNT(*) FROM stg.txn);
    PRINT 'Raw rows: ' + CAST(@raw AS VARCHAR(10))
        + ' | event rows kept: ' + CAST(@kept AS VARCHAR(10))
        + ' | duplicates removed: ' + CAST(@raw - @kept AS VARCHAR(10));
END
GO

/* ------------------------------------------------------------
   2. DIMENSIONS
   ------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dw.load_dimensions
AS
BEGIN
    SET NOCOUNT ON;

    /* ---- dim_date: one row for every day from 2022-01-01 to 2026-12-31 ---- */
    DECLARE @d DATE = '2022-01-01';
    WHILE @d <= '2026-12-31'
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dw.dim_date WHERE full_date = @d)
            INSERT INTO dw.dim_date
                (date_key, full_date, [year], [quarter], month_num, month_name,
                 year_month, month_start, day_of_month, day_name, is_weekend)
            VALUES
                (CONVERT(INT, CONVERT(CHAR(8), @d, 112)), @d, YEAR(@d), DATEPART(QUARTER, @d), MONTH(@d),
                 DATENAME(MONTH, @d), CONVERT(CHAR(7), @d, 126), DATEFROMPARTS(YEAR(@d), MONTH(@d), 1),
                 DAY(@d), DATENAME(WEEKDAY, @d),
                 CASE WHEN DATEDIFF(DAY, '19000101', @d) % 7 IN (5, 6) THEN 1 ELSE 0 END);  -- 1 Jan 1900 was a Monday
        SET @d = DATEADD(DAY, 1, @d);
    END

    /* ---- dim_product ---- */
    INSERT INTO dw.dim_product (product_type)
    SELECT DISTINCT s.product_type
    FROM (SELECT product_type FROM stg.enrollment
          UNION
          SELECT product_type FROM stg.txn WHERE product_type IS NOT NULL) s
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_product d WHERE d.product_type = s.product_type);

    /* ---- dim_channel ---- */
    INSERT INTO dw.dim_channel (channel_name)
    SELECT DISTINCT s.channel
    FROM (SELECT channel FROM stg.interaction
          UNION
          SELECT channel FROM stg.txn) s
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_channel d WHERE d.channel_name = s.channel);

    /* ---- dim_interaction_type ---- */
    INSERT INTO dw.dim_interaction_type (interaction_type)
    SELECT DISTINCT s.interaction_type
    FROM stg.interaction s
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_interaction_type d WHERE d.interaction_type = s.interaction_type);

    /* ---- dim_transaction_type ---- */
    INSERT INTO dw.dim_transaction_type (transaction_type, cash_flow)
    SELECT DISTINCT s.transaction_type,
           CASE WHEN s.transaction_type IN ('Deposit', 'EFT Payment', 'Refund') THEN 'Credit' ELSE 'Debit' END
    FROM stg.txn s
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_transaction_type d WHERE d.transaction_type = s.transaction_type);

    /* ---- dim_client (SCD Type 1: overwrite old details, add new clients) ---- */
    UPDATE d
    SET first_name           = s.first_name,
        last_name            = s.last_name,
        email                = s.email,
        email_status         = s.email_status,
        mobile_e164          = s.mobile_e164,
        date_of_birth        = s.date_of_birth,
        gender               = s.gender,
        province             = s.province,
        city                 = s.city,
        signup_date          = s.signup_date,
        signup_date_key      = CONVERT(INT, CONVERT(CHAR(8), s.signup_date, 112)),
        duplicate_email_flag = s.duplicate_email_flag
    FROM dw.dim_client d
    JOIN stg.client s ON s.client_number = d.client_number;

    INSERT INTO dw.dim_client
        (client_number, first_name, last_name, email, email_status, mobile_e164, date_of_birth,
         gender, province, city, signup_date, signup_date_key, duplicate_email_flag)
    SELECT s.client_number, s.first_name, s.last_name, s.email, s.email_status, s.mobile_e164, s.date_of_birth,
           s.gender, s.province, s.city, s.signup_date, CONVERT(INT, CONVERT(CHAR(8), s.signup_date, 112)),
           s.duplicate_email_flag
    FROM stg.client s
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_client d WHERE d.client_number = s.client_number);

    /* ---- dim_account ---- */
    -- update the status of accounts we already have
    UPDATE a
    SET account_status = e.account_status,
        is_inferred    = 0
    FROM dw.dim_account a
    JOIN stg.enrollment e ON e.account_number = a.account_number;

    -- add the enrolled accounts
    INSERT INTO dw.dim_account (account_number, account_status, is_inferred)
    SELECT e.account_number, e.account_status, 0
    FROM stg.enrollment e
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_account a WHERE a.account_number = e.account_number);

    -- accounts that appear in transactions but were never enrolled (we keep them, flagged)
    INSERT INTO dw.dim_account (account_number, account_status, is_inferred)
    SELECT DISTINCT t.account_number, 'Unknown', 1
    FROM stg.txn t
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_account a WHERE a.account_number = t.account_number);
END
GO

/* ------------------------------------------------------------
   3. FACTS  (dimensions must be loaded first)
   ------------------------------------------------------------ */
CREATE OR ALTER PROCEDURE dw.load_facts
AS
BEGIN
    SET NOCOUNT ON;

    /* ---- fact_account: one row per account ---- */
    INSERT INTO dw.fact_account
        (account_key, client_key, product_key, enrollment_date_key, credit_limit, loan_amount, account_balance)
    SELECT a.account_key, c.client_key, p.product_key, d.date_key,
           e.credit_limit, e.loan_amount, e.account_balance
    FROM stg.enrollment e
    JOIN dw.dim_account a ON a.account_number = e.account_number
    JOIN dw.dim_client  c ON c.client_number  = e.client_number
    JOIN dw.dim_product p ON p.product_type   = e.product_type
    JOIN dw.dim_date    d ON d.full_date      = e.enrollment_date
    WHERE NOT EXISTS (SELECT 1 FROM dw.fact_account f WHERE f.account_key = a.account_key);

    /* ---- fact_interaction: one row per CRM interaction ---- */
    INSERT INTO dw.fact_interaction (client_key, date_key, channel_key, interaction_type_key, resolved_flag)
    SELECT c.client_key, d.date_key, ch.channel_key, it.interaction_type_key, s.resolved_flag
    FROM stg.interaction s
    JOIN dw.dim_client           c  ON c.client_number    = s.client_number
    JOIN dw.dim_date             d  ON d.full_date        = s.event_date
    JOIN dw.dim_channel          ch ON ch.channel_name    = s.channel
    JOIN dw.dim_interaction_type it ON it.interaction_type = s.interaction_type
    WHERE NOT EXISTS (SELECT 1 FROM dw.fact_interaction f
                      WHERE f.client_key           = c.client_key
                        AND f.date_key             = d.date_key
                        AND f.channel_key          = ch.channel_key
                        AND f.interaction_type_key = it.interaction_type_key
                        AND f.resolved_flag        = s.resolved_flag);

    /* ---- fact_transaction: one row per transaction ---- */
    INSERT INTO dw.fact_transaction
        (client_key, account_key, product_key, date_key, channel_key, transaction_type_key, amount)
    SELECT c.client_key, a.account_key, p.product_key, d.date_key, ch.channel_key, tt.transaction_type_key, s.amount
    FROM stg.txn s
    JOIN dw.dim_client           c  ON c.client_number     = s.client_number
    JOIN dw.dim_account          a  ON a.account_number    = s.account_number
    JOIN dw.dim_product          p  ON p.product_type      = s.product_type
    JOIN dw.dim_date             d  ON d.full_date         = s.event_date
    JOIN dw.dim_channel          ch ON ch.channel_name     = s.channel
    JOIN dw.dim_transaction_type tt ON tt.transaction_type = s.transaction_type
    WHERE NOT EXISTS (SELECT 1 FROM dw.fact_transaction f
                      WHERE f.client_key           = c.client_key
                        AND f.account_key          = a.account_key
                        AND f.date_key             = d.date_key
                        AND f.channel_key          = ch.channel_key
                        AND f.transaction_type_key = tt.transaction_type_key
                        AND f.amount               = s.amount);

    /* ---- checks: every staging row must be in the warehouse ---- */
    IF (SELECT COUNT(*) FROM dw.fact_transaction) <> (SELECT COUNT(*) FROM stg.txn)
        THROW 50030, 'fact_transaction does not have the same number of rows as stg.txn.', 1;
    IF (SELECT COUNT(*) FROM dw.fact_interaction) <> (SELECT COUNT(*) FROM stg.interaction)
        THROW 50031, 'fact_interaction does not have the same number of rows as stg.interaction.', 1;
    IF (SELECT COUNT(*) FROM dw.fact_account) <> (SELECT COUNT(*) FROM stg.enrollment)
        THROW 50032, 'fact_account does not have the same number of rows as stg.enrollment.', 1;
END
GO
