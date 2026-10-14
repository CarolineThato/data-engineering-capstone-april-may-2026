/* ============================================================
   02_etl_procs.sql  -  three re-runnable procedures
   SSIS control flow order:  stg.usp_load_staging
                          -> dw.usp_load_dimensions
                          -> dw.usp_load_facts
   Re-run safety: staging is truncated and rebuilt; dimensions and
   facts use WHERE NOT EXISTS (plus an SCD1 UPDATE on dim_client /
   dim_account), so running twice never duplicates rows.
   Failing loudly: THROW stops the package with a clear message.
   ============================================================ */
USE Customer360_DW;
GO
CREATE OR ALTER PROCEDURE stg.usp_load_staging AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM source.customer_activity_extract)
        THROW 50001, 'Raw table is empty - run package 01 (load CSV) first.', 1;

    TRUNCATE TABLE stg.dq_issue; TRUNCATE TABLE stg.client; TRUNCATE TABLE stg.enrollment;
    TRUNCATE TABLE stg.interaction; TRUNCATE TABLE stg.txn;

    /* 1. trim + blank -> NULL (+ strip phone punctuation) */
    DROP TABLE IF EXISTS #t;
    SELECT source_row_id,
      UPPER(NULLIF(LTRIM(RTRIM(client_number)),''))  client_number,
      NULLIF(LTRIM(RTRIM(first_name)),'')  first_name, NULLIF(LTRIM(RTRIM(last_name)),'') last_name,
      LOWER(NULLIF(LTRIM(RTRIM(email)),''))  email,
      NULLIF(REPLACE(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(mobile_number)),' ',''),'-',''),'(',''),')',''),'') mobile_clean,
      NULLIF(LTRIM(RTRIM(date_of_birth)),'') dob_raw,  UPPER(NULLIF(LTRIM(RTRIM(gender)),'')) gender,
      NULLIF(LTRIM(RTRIM(province)),'') province, NULLIF(LTRIM(RTRIM(city)),'') city,
      NULLIF(LTRIM(RTRIM(signup_date)),'') signup_raw, NULLIF(LTRIM(RTRIM(event_type)),'') event_type,
      NULLIF(LTRIM(RTRIM(event_date)),'') event_raw, UPPER(NULLIF(LTRIM(RTRIM(account_number)),'')) account_number,
      NULLIF(LTRIM(RTRIM(product_type)),'') product_type, NULLIF(LTRIM(RTRIM(account_status)),'') account_status,
      NULLIF(LTRIM(RTRIM(credit_limit)),'') credit_raw, NULLIF(LTRIM(RTRIM(loan_amount)),'') loan_raw,
      NULLIF(LTRIM(RTRIM(account_balance)),'') balance_raw, NULLIF(LTRIM(RTRIM(channel)),'') channel,
      NULLIF(LTRIM(RTRIM(interaction_type)),'') interaction_type,
      UPPER(NULLIF(LTRIM(RTRIM(resolved_flag)),'')) resolved_flag,
      NULLIF(LTRIM(RTRIM(transaction_type)),'') transaction_type, NULLIF(LTRIM(RTRIM(amount)),'') amount_raw
    INTO #t FROM source.customer_activity_extract;

    /* 2. typed + hashed copy */
    DROP TABLE IF EXISTS #c;
    SELECT t.*,
      TRY_CONVERT(DATE, dob_raw, 23) dob, TRY_CONVERT(DATE, signup_raw, 23) signup_date,
      TRY_CONVERT(DATE, event_raw, 23) event_date, TRY_CONVERT(DECIMAL(18,2), credit_raw) credit_limit,
      TRY_CONVERT(DECIMAL(18,2), loan_raw) loan_amount, TRY_CONVERT(DECIMAL(18,2), balance_raw) account_balance,
      TRY_CONVERT(DECIMAL(18,2), amount_raw) amount,
      CASE WHEN mobile_clean IS NULL THEN NULL
        WHEN mobile_clean NOT LIKE '%[^0-9]%' AND LEN(mobile_clean)=10 AND LEFT(mobile_clean,1)='0' THEN '+27'+SUBSTRING(mobile_clean,2,9)
        WHEN mobile_clean NOT LIKE '%[^0-9]%' AND LEN(mobile_clean)=11 AND LEFT(mobile_clean,2)='27' THEN '+'+mobile_clean
        WHEN LEN(mobile_clean)=12 AND LEFT(mobile_clean,3)='+27' AND SUBSTRING(mobile_clean,2,11) NOT LIKE '%[^0-9]%' THEN mobile_clean
      END mobile_e164,
      HASHBYTES('SHA2_256', CONCAT(client_number,'|',first_name,'|',last_name,'|',email,'|',mobile_clean,'|',dob_raw,'|',gender,'|',
         province,'|',city,'|',signup_raw,'|',event_type,'|',event_raw,'|',account_number,'|',product_type,'|',account_status,'|',
         credit_raw,'|',loan_raw,'|',balance_raw,'|',channel,'|',interaction_type,'|',resolved_flag,'|',transaction_type,'|',amount_raw)) row_hash
    INTO #c FROM #t t;

    /* 3. exact duplicate rows: keep first, log the rest */
    DROP TABLE IF EXISTS #d;
    SELECT *, ROW_NUMBER() OVER (PARTITION BY row_hash ORDER BY source_row_id) dup_rank INTO #d FROM #c;
    INSERT stg.dq_issue(rule_name,severity,entity_key,source_row_id,detail)
    SELECT 'EXACT_DUPLICATE_ROW','WARN',client_number,source_row_id,'Identical to an earlier row; excluded' FROM #d WHERE dup_rank>1;
    DELETE FROM #d WHERE dup_rank>1;

    /* 4. FAIL LOUDLY on structural problems (these cannot be "fixed") */
    IF EXISTS (SELECT 1 FROM #d WHERE event_type NOT IN ('Product Enrollment','CRM Interaction','Transaction') OR event_type IS NULL)
        THROW 50002, 'Unknown or missing event_type found in raw data.', 1;
    IF EXISTS (SELECT 1 FROM #d WHERE client_number IS NULL OR signup_date IS NULL OR event_date IS NULL)
        THROW 50003, 'Missing/unparseable client_number, signup_date or event_date.', 1;
    IF EXISTS (SELECT 1 FROM #d WHERE (amount_raw IS NOT NULL AND amount IS NULL) OR (balance_raw IS NOT NULL AND account_balance IS NULL)
                                   OR (credit_raw IS NOT NULL AND credit_limit IS NULL) OR (loan_raw IS NOT NULL AND loan_amount IS NULL))
        THROW 50004, 'Non-numeric value in amount/balance/credit_limit/loan_amount.', 1;
    IF EXISTS (SELECT 1 FROM #d WHERE event_type='Transaction' AND (account_number IS NULL OR amount IS NULL OR transaction_type IS NULL OR channel IS NULL))
        THROW 50005, 'Transaction row missing account, amount, type or channel.', 1;
    IF EXISTS (SELECT 1 FROM #d WHERE event_type='CRM Interaction' AND (interaction_type IS NULL OR channel IS NULL))
        THROW 50006, 'CRM row missing interaction_type or channel.', 1;
    IF EXISTS (SELECT 1 FROM #d WHERE event_type='Product Enrollment' AND (account_number IS NULL OR product_type IS NULL OR account_status IS NULL))
        THROW 50007, 'Enrollment row missing account, product or status.', 1;

    /* 5. CLIENT: one row per client_number (latest event wins), cleaned */
    ;WITH c AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY client_number ORDER BY event_date DESC, source_row_id DESC) rn FROM #d)
    INSERT stg.client(client_number,first_name,last_name,email,email_status,mobile_e164,date_of_birth,gender,province,city,signup_date,duplicate_email_flag)
    SELECT client_number, first_name, last_name, email,
        CASE WHEN email IS NULL THEN 'Missing'
             WHEN email LIKE '%_@_%._%' AND email NOT LIKE '% %' THEN 'Valid' ELSE 'Invalid' END,
        mobile_e164, dob,
        CASE gender WHEN 'M' THEN 'Male' WHEN 'F' THEN 'Female' ELSE 'Unknown' END,
        province, city, signup_date,
        CASE WHEN email IS NOT NULL AND COUNT(*) OVER (PARTITION BY email)>1 THEN 1 ELSE 0 END
    FROM c WHERE rn=1;

    /* client attributes that disagree between rows (none expected) */
    INSERT stg.dq_issue(rule_name,severity,entity_key,detail)
    SELECT 'CLIENT_ATTRIBUTE_CONFLICT','WARN',client_number,'Client details differ between rows; latest used'
    FROM #d GROUP BY client_number
    HAVING COUNT(DISTINCT CONCAT(first_name,last_name,email,mobile_clean,dob_raw,gender,province,city,signup_raw))>1;

    /* data quality log at client level */
    INSERT stg.dq_issue(rule_name,severity,entity_key,detail)
    SELECT 'EMAIL_'+UPPER(email_status),'WARN',client_number,'Email '+LOWER(email_status) FROM stg.client WHERE email_status<>'Valid';
    INSERT stg.dq_issue(rule_name,severity,entity_key,detail)
    SELECT 'MOBILE_MISSING_OR_UNRECOGNISED','WARN',client_number,'No usable mobile number' FROM stg.client WHERE mobile_e164 IS NULL;
    INSERT stg.dq_issue(rule_name,severity,entity_key,detail)
    SELECT 'DUPLICATE_EMAIL_ACROSS_CLIENTS','WARN',client_number,email FROM stg.client WHERE duplicate_email_flag=1;
    INSERT stg.dq_issue(rule_name,severity,entity_key,detail)
    SELECT 'GENDER_UNKNOWN','INFO',client_number,'Blank or U' FROM stg.client WHERE gender='Unknown';

    /* 6. THE SPLIT (SQL equivalent of an SSIS Conditional Split on event_type) */
    INSERT stg.enrollment(account_number,client_number,product_type,account_status,enrollment_date,credit_limit,loan_amount,account_balance,source_row_id)
    SELECT account_number,client_number,product_type,account_status,event_date,credit_limit,loan_amount,account_balance,source_row_id
    FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY account_number ORDER BY event_date DESC, source_row_id DESC) rn
          FROM #d WHERE event_type='Product Enrollment') e WHERE rn=1;

    INSERT stg.interaction(row_hash,client_number,event_date,channel,interaction_type,resolved_flag,source_row_id)
    SELECT row_hash,client_number,event_date,channel,interaction_type,
           CASE WHEN resolved_flag IN ('Y','N') THEN resolved_flag ELSE 'U' END, source_row_id
    FROM #d WHERE event_type='CRM Interaction';
    INSERT stg.dq_issue(rule_name,severity,entity_key,source_row_id,detail)
    SELECT 'RESOLVED_FLAG_MISSING','WARN',client_number,source_row_id,'Stored as U(nknown), excluded from resolution rates'
    FROM stg.interaction WHERE resolved_flag='U';

    INSERT stg.txn(row_hash,client_number,account_number,product_type,event_date,channel,transaction_type,amount,source_row_id)
    SELECT row_hash,client_number,account_number,product_type,event_date,channel,transaction_type,amount,source_row_id
    FROM #d WHERE event_type='Transaction';
    INSERT stg.dq_issue(rule_name,severity,entity_key,source_row_id,detail)
    SELECT 'ORPHAN_ACCOUNT','WARN',account_number,source_row_id,'Transaction on account with no enrollment row; kept, account inferred'
    FROM stg.txn t WHERE NOT EXISTS (SELECT 1 FROM stg.enrollment e WHERE e.account_number=t.account_number);
    INSERT stg.dq_issue(rule_name,severity,entity_key,source_row_id,detail)
    SELECT 'ZERO_AMOUNT_TRANSACTION','INFO',account_number,source_row_id,'Amount = 0; kept' FROM stg.txn WHERE amount=0;

    /* 7. reconciliation: nothing silently lost */
    DECLARE @in INT=(SELECT COUNT(*) FROM #d),
            @out INT=(SELECT (SELECT COUNT(*) FROM stg.enrollment)+(SELECT COUNT(*) FROM stg.interaction)+(SELECT COUNT(*) FROM stg.txn));
    IF @in<>@out THROW 50008, 'Staging row count does not reconcile to raw (check duplicate account_number in enrollments).', 1;
END
GO
CREATE OR ALTER PROCEDURE dw.usp_load_dimensions AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    /* ---- dim_date (2022-01-01 .. 2026-12-31) + Unknown ---- */
    IF NOT EXISTS (SELECT 1 FROM dw.dim_date WHERE date_key=-1)
        INSERT dw.dim_date VALUES(-1,'1900-01-01',1900,1,1,'Unknown','1900-01',NULL,1,'Unknown',0);
    ;WITH d AS (SELECT CAST('2022-01-01' AS DATE) dt UNION ALL SELECT DATEADD(DAY,1,dt) FROM d WHERE dt<'2026-12-31')
    INSERT dw.dim_date(date_key,full_date,[year],[quarter],month_num,month_name,year_month,month_start,day_of_month,day_name,is_weekend)
    SELECT CONVERT(INT,CONVERT(CHAR(8),dt,112)), dt, YEAR(dt), DATEPART(QUARTER,dt), MONTH(dt), DATENAME(MONTH,dt),
           CONVERT(CHAR(7),dt,126), DATEFROMPARTS(YEAR(dt),MONTH(dt),1), DAY(dt), DATENAME(WEEKDAY,dt),
           CASE WHEN DATEDIFF(DAY,'19000101',dt)%7 IN (5,6) THEN 1 ELSE 0 END      -- 1900-01-01 was a Monday
    FROM d WHERE NOT EXISTS (SELECT 1 FROM dw.dim_date x WHERE x.full_date=d.dt) OPTION (MAXRECURSION 0);

    /* ---- small dimensions: Unknown member + new values only ---- */
    SET IDENTITY_INSERT dw.dim_product ON;
    IF NOT EXISTS (SELECT 1 FROM dw.dim_product WHERE product_key=-1) INSERT dw.dim_product(product_key,product_type) VALUES(-1,'Unknown');
    SET IDENTITY_INSERT dw.dim_product OFF;
    INSERT dw.dim_product(product_type)
    SELECT DISTINCT p FROM (SELECT product_type p FROM stg.enrollment UNION SELECT product_type FROM stg.txn WHERE product_type IS NOT NULL) s
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_product d WHERE d.product_type=s.p);

    SET IDENTITY_INSERT dw.dim_channel ON;
    IF NOT EXISTS (SELECT 1 FROM dw.dim_channel WHERE channel_key=-1) INSERT dw.dim_channel(channel_key,channel_name) VALUES(-1,'Unknown');
    SET IDENTITY_INSERT dw.dim_channel OFF;
    INSERT dw.dim_channel(channel_name)
    SELECT DISTINCT c FROM (SELECT channel c FROM stg.interaction UNION SELECT channel FROM stg.txn) s
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_channel d WHERE d.channel_name=s.c);

    SET IDENTITY_INSERT dw.dim_interaction_type ON;
    IF NOT EXISTS (SELECT 1 FROM dw.dim_interaction_type WHERE interaction_type_key=-1) INSERT dw.dim_interaction_type(interaction_type_key,interaction_type) VALUES(-1,'Unknown');
    SET IDENTITY_INSERT dw.dim_interaction_type OFF;
    INSERT dw.dim_interaction_type(interaction_type)
    SELECT DISTINCT interaction_type FROM stg.interaction s
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_interaction_type d WHERE d.interaction_type=s.interaction_type);

    SET IDENTITY_INSERT dw.dim_transaction_type ON;
    IF NOT EXISTS (SELECT 1 FROM dw.dim_transaction_type WHERE transaction_type_key=-1) INSERT dw.dim_transaction_type(transaction_type_key,transaction_type,cash_flow) VALUES(-1,'Unknown','Unknown');
    SET IDENTITY_INSERT dw.dim_transaction_type OFF;
    INSERT dw.dim_transaction_type(transaction_type,cash_flow)
    SELECT transaction_type,
           CASE WHEN transaction_type IN ('Deposit','EFT Payment','Refund') THEN 'Credit' ELSE 'Debit' END   -- matches the sign observed in the data
    FROM (SELECT DISTINCT transaction_type FROM stg.txn) s
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_transaction_type d WHERE d.transaction_type=s.transaction_type);

    /* ---- dim_client (SCD Type 1) ---- */
    SET IDENTITY_INSERT dw.dim_client ON;
    IF NOT EXISTS (SELECT 1 FROM dw.dim_client WHERE client_key=-1)
        INSERT dw.dim_client(client_key,client_number,email_status,gender,signup_date_key,duplicate_email_flag) VALUES(-1,'UNKNOWN','Missing','Unknown',-1,0);
    SET IDENTITY_INSERT dw.dim_client OFF;

    UPDATE d SET first_name=s.first_name,last_name=s.last_name,email=s.email,email_status=s.email_status,mobile_e164=s.mobile_e164,
                 date_of_birth=s.date_of_birth,gender=s.gender,province=s.province,city=s.city,
                 signup_date=s.signup_date,signup_date_key=CONVERT(INT,CONVERT(CHAR(8),s.signup_date,112)),duplicate_email_flag=s.duplicate_email_flag
    FROM dw.dim_client d JOIN stg.client s ON s.client_number=d.client_number
    WHERE EXISTS (SELECT s.first_name,s.last_name,s.email,s.email_status,s.mobile_e164,s.date_of_birth,s.gender,s.province,s.city,s.signup_date,s.duplicate_email_flag
                  EXCEPT SELECT d.first_name,d.last_name,d.email,d.email_status,d.mobile_e164,d.date_of_birth,d.gender,d.province,d.city,d.signup_date,d.duplicate_email_flag);

    INSERT dw.dim_client(client_number,first_name,last_name,email,email_status,mobile_e164,date_of_birth,gender,province,city,signup_date,signup_date_key,duplicate_email_flag)
    SELECT s.client_number,s.first_name,s.last_name,s.email,s.email_status,s.mobile_e164,s.date_of_birth,s.gender,s.province,s.city,
           s.signup_date,CONVERT(INT,CONVERT(CHAR(8),s.signup_date,112)),s.duplicate_email_flag
    FROM stg.client s WHERE NOT EXISTS (SELECT 1 FROM dw.dim_client d WHERE d.client_number=s.client_number);

    /* ---- dim_account: enrolled accounts + inferred orphans ---- */
    UPDATE d SET account_status=e.account_status
    FROM dw.dim_account d JOIN stg.enrollment e ON e.account_number=d.account_number
    WHERE d.account_status<>e.account_status OR d.is_inferred=1;
    UPDATE d SET is_inferred=0 FROM dw.dim_account d JOIN stg.enrollment e ON e.account_number=d.account_number WHERE d.is_inferred=1;

    INSERT dw.dim_account(account_number,account_status,is_inferred)
    SELECT e.account_number,e.account_status,0 FROM stg.enrollment e
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_account d WHERE d.account_number=e.account_number);
    INSERT dw.dim_account(account_number,account_status,is_inferred)
    SELECT DISTINCT t.account_number,'Unknown',1 FROM stg.txn t
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_account d WHERE d.account_number=t.account_number);

    /* fail loudly: every event date must exist in dim_date */
    IF EXISTS (SELECT 1 FROM (SELECT event_date FROM stg.txn UNION SELECT event_date FROM stg.interaction UNION SELECT enrollment_date FROM stg.enrollment UNION SELECT signup_date FROM stg.client) x
               WHERE NOT EXISTS (SELECT 1 FROM dw.dim_date d WHERE d.full_date=x.event_date))
        THROW 50020, 'A source date falls outside dim_date range - extend the date dimension.', 1;
END
GO
CREATE OR ALTER PROCEDURE dw.usp_load_facts AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    /* fact_account: grain = 1 row per account */
    INSERT dw.fact_account(account_key,client_key,product_key,enrollment_date_key,credit_limit,loan_amount,account_balance)
    SELECT a.account_key, ISNULL(c.client_key,-1), ISNULL(p.product_key,-1), CONVERT(INT,CONVERT(CHAR(8),e.enrollment_date,112)),
           e.credit_limit, e.loan_amount, e.account_balance
    FROM stg.enrollment e
    JOIN dw.dim_account a ON a.account_number=e.account_number
    LEFT JOIN dw.dim_client c ON c.client_number=e.client_number
    LEFT JOIN dw.dim_product p ON p.product_type=e.product_type
    WHERE NOT EXISTS (SELECT 1 FROM dw.fact_account f WHERE f.account_key=a.account_key);

    /* fact_interaction: grain = 1 CRM interaction */
    INSERT dw.fact_interaction(row_hash,source_row_id,client_key,date_key,channel_key,interaction_type_key,resolved_flag)
    SELECT s.row_hash,s.source_row_id,ISNULL(c.client_key,-1),CONVERT(INT,CONVERT(CHAR(8),s.event_date,112)),
           ISNULL(ch.channel_key,-1),ISNULL(it.interaction_type_key,-1),s.resolved_flag
    FROM stg.interaction s
    LEFT JOIN dw.dim_client c ON c.client_number=s.client_number
    LEFT JOIN dw.dim_channel ch ON ch.channel_name=s.channel
    LEFT JOIN dw.dim_interaction_type it ON it.interaction_type=s.interaction_type
    WHERE NOT EXISTS (SELECT 1 FROM dw.fact_interaction f WHERE f.row_hash=s.row_hash);

    /* fact_transaction: grain = 1 transaction */
    INSERT dw.fact_transaction(row_hash,source_row_id,client_key,account_key,product_key,date_key,channel_key,transaction_type_key,amount)
    SELECT s.row_hash,s.source_row_id,ISNULL(c.client_key,-1),a.account_key,ISNULL(p.product_key,-1),
           CONVERT(INT,CONVERT(CHAR(8),s.event_date,112)),ISNULL(ch.channel_key,-1),ISNULL(tt.transaction_type_key,-1),s.amount
    FROM stg.txn s
    JOIN dw.dim_account a ON a.account_number=s.account_number
    LEFT JOIN dw.dim_client c ON c.client_number=s.client_number
    LEFT JOIN dw.dim_product p ON p.product_type=s.product_type
    LEFT JOIN dw.dim_channel ch ON ch.channel_name=s.channel
    LEFT JOIN dw.dim_transaction_type tt ON tt.transaction_type=s.transaction_type
    WHERE NOT EXISTS (SELECT 1 FROM dw.fact_transaction f WHERE f.row_hash=s.row_hash);

    /* FAIL LOUDLY: reconcile + no Unknown client / channel / type */
    IF EXISTS (SELECT 1 FROM stg.txn s WHERE NOT EXISTS (SELECT 1 FROM dw.fact_transaction f WHERE f.row_hash=s.row_hash))
        THROW 50030, 'Some staged transactions did not reach fact_transaction.', 1;
    IF EXISTS (SELECT 1 FROM stg.interaction s WHERE NOT EXISTS (SELECT 1 FROM dw.fact_interaction f WHERE f.row_hash=s.row_hash))
        THROW 50031, 'Some staged interactions did not reach fact_interaction.', 1;
    IF (SELECT COUNT(*) FROM stg.enrollment)<>(SELECT COUNT(*) FROM dw.fact_account fa JOIN dw.dim_account a ON a.account_key=fa.account_key WHERE a.is_inferred=0)
        THROW 50032, 'fact_account row count does not match enrollments.', 1;
    IF EXISTS (SELECT 1 FROM dw.fact_transaction WHERE client_key=-1 OR channel_key=-1 OR transaction_type_key=-1)
       OR EXISTS (SELECT 1 FROM dw.fact_interaction WHERE client_key=-1 OR channel_key=-1 OR interaction_type_key=-1)
       OR EXISTS (SELECT 1 FROM dw.fact_account WHERE client_key=-1 OR product_key=-1)
        THROW 50033, 'Fact rows were assigned to an Unknown dimension member.', 1;
END
GO
