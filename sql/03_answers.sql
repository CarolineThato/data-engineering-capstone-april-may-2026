/*
    Business-question answers

    Run this script after the dimensional model and facts have been loaded.
    All queries use the dw schema. Amounts are shown as gross (absolute)
    value where the question asks for transaction value; signed amounts are
    also included where useful to show money in versus money out.
*/

/* 1. Customers per province and share of the customer base */
SELECT
    province,
    COUNT(*) AS customers,
    CAST(
        100.0 * COUNT(*) / (SELECT COUNT(*) FROM dw.dim_client)
        AS DECIMAL(5, 2)
    ) AS pct_of_total
FROM dw.dim_client
GROUP BY province
ORDER BY customers DESC;

/* 2. Customer age distribution
   Age is measured on the latest event date. The bands use 10-year ranges. */
DECLARE @age_reference_date DATE =
    (SELECT latest_event_date FROM dw.vw_ref);

SELECT
    age_band,
    COUNT(*) AS customers
FROM (
    SELECT
        CASE
            WHEN age < 25 THEN '1. 18-24'
            WHEN age < 35 THEN '2. 25-34'
            WHEN age < 45 THEN '3. 35-44'
            WHEN age < 55 THEN '4. 45-54'
            WHEN age < 65 THEN '5. 55-64'
            ELSE '6. 65+'
        END AS age_band
    FROM (
        SELECT
            DATEDIFF(YEAR, date_of_birth, @age_reference_date)
            - CASE
                WHEN MONTH(date_of_birth) * 100 + DAY(date_of_birth)
                     > MONTH(@age_reference_date) * 100
                       + DAY(@age_reference_date)
                THEN 1
                ELSE 0
              END AS age
        FROM dw.dim_client
    ) AS customer_ages
) AS banded_customers
GROUP BY age_band
ORDER BY age_band;

/* 3. Signups by month for the last two years
   Compare the first 12 months with the latest 12 months for a simple trend. */
DECLARE @latest_signup_month DATE = (
    SELECT DATEFROMPARTS(YEAR(latest_signup_date), MONTH(latest_signup_date), 1)
    FROM dw.vw_ref
);

SELECT
    d.year_month,
    COUNT(*) AS signups
FROM dw.dim_client AS c
JOIN dw.dim_date AS d
    ON d.date_key = c.signup_date_key
WHERE d.month_start >= DATEADD(MONTH, -23, @latest_signup_month)
GROUP BY d.year_month
ORDER BY d.year_month;

SELECT
    SUM(CASE WHEN month_number <= 12 THEN signups END) AS first_12_months,
    SUM(CASE WHEN month_number > 12 THEN signups END) AS last_12_months
FROM (
    SELECT
        d.year_month,
        COUNT(*) AS signups,
        ROW_NUMBER() OVER (ORDER BY d.year_month) AS month_number
    FROM dw.dim_client AS c
    JOIN dw.dim_date AS d
        ON d.date_key = c.signup_date_key
    WHERE d.month_start >= DATEADD(MONTH, -23, @latest_signup_month)
    GROUP BY d.year_month
) AS monthly_signups;

/* 4. Data quality issues in customer records */
SELECT
    COUNT(*) AS total_clients,
    SUM(CASE WHEN email_status = 'Missing' THEN 1 ELSE 0 END) AS missing_email,
    SUM(CASE WHEN email_status = 'Invalid' THEN 1 ELSE 0 END) AS invalid_email,
    SUM(CASE WHEN mobile_e164 IS NULL THEN 1 ELSE 0 END) AS no_mobile,
    SUM(CASE WHEN duplicate_email_flag = 1 THEN 1 ELSE 0 END) AS shared_email,
    SUM(
        CASE
            WHEN email_status <> 'Valid'
              OR mobile_e164 IS NULL
              OR duplicate_email_flag = 1
            THEN 1
            ELSE 0
        END
    ) AS clients_with_any_problem
FROM dw.dim_client;

/* 5. Product ownership and cross-holding */
-- Number of customers holding each product (closed accounts are excluded).
SELECT
    p.product_type,
    COUNT(DISTINCT f.client_key) AS customers_holding
FROM dw.fact_account AS f
JOIN dw.dim_account AS a
    ON a.account_key = f.account_key
JOIN dw.dim_product AS p
    ON p.product_key = f.product_key
WHERE a.account_status <> 'Closed'
GROUP BY p.product_type
ORDER BY customers_holding DESC;

-- Number of different products held by each customer.
SELECT
    products_held,
    COUNT(*) AS customers
FROM (
    SELECT
        f.client_key,
        COUNT(DISTINCT f.product_key) AS products_held
    FROM dw.fact_account AS f
    JOIN dw.dim_account AS a
        ON a.account_key = f.account_key
    WHERE a.account_status <> 'Closed'
    GROUP BY f.client_key
) AS customer_products
GROUP BY products_held
ORDER BY products_held;

/* 6. Total and average account balance by product type */
SELECT
    p.product_type,
    SUM(
        CASE WHEN a.account_status <> 'Closed'
             THEN f.account_balance
        END
    ) AS total_balance_open,
    AVG(
        CASE WHEN a.account_status <> 'Closed'
             THEN f.account_balance
        END
    ) AS avg_balance_open,
    SUM(f.account_balance) AS total_balance_all,
    AVG(f.account_balance) AS avg_balance_all
FROM dw.fact_account AS f
JOIN dw.dim_account AS a
    ON a.account_key = f.account_key
JOIN dw.dim_product AS p
    ON p.product_key = f.product_key
GROUP BY p.product_type;

/* 7. Customers with Savings but no Credit Card */
SELECT
    COUNT(DISTINCT f.client_key) AS savings_but_no_credit_card
FROM dw.fact_account AS f
JOIN dw.dim_account AS a
    ON a.account_key = f.account_key
JOIN dw.dim_product AS p
    ON p.product_key = f.product_key
WHERE p.product_type = 'Savings'
  AND a.account_status <> 'Closed'
  AND NOT EXISTS (
      SELECT 1
      FROM dw.fact_account AS credit_card
      JOIN dw.dim_account AS credit_card_account
          ON credit_card_account.account_key = credit_card.account_key
      JOIN dw.dim_product AS credit_card_product
          ON credit_card_product.product_key = credit_card.product_key
      WHERE credit_card.client_key = f.client_key
        AND credit_card_product.product_type = 'Credit Card'
        AND credit_card_account.account_status <> 'Closed'
  );

/* 8. Open Credit Card accounts at or above 90% of their limit */
SELECT
    COUNT(*) AS open_cards,
    SUM(
        CASE WHEN f.account_balance >= 0.9 * f.credit_limit
             THEN 1
             ELSE 0
        END
    ) AS near_limit,
    CAST(
        100.0 * SUM(
            CASE WHEN f.account_balance >= 0.9 * f.credit_limit
                 THEN 1
                 ELSE 0
            END
        ) / COUNT(*)
        AS DECIMAL(5, 2)
    ) AS pct_near_limit
FROM dw.fact_account AS f
JOIN dw.dim_account AS a
    ON a.account_key = f.account_key
JOIN dw.dim_product AS p
    ON p.product_key = f.product_key
WHERE p.product_type = 'Credit Card'
  AND a.account_status <> 'Closed';

/* 9. Monthly transaction value by transaction type */
SELECT
    d.year_month,
    tt.transaction_type,
    COUNT(*) AS txns,
    SUM(f.amount_abs) AS gross_value,
    SUM(f.amount) AS net_value
FROM dw.fact_transaction AS f
JOIN dw.dim_date AS d
    ON d.date_key = f.date_key
JOIN dw.dim_transaction_type AS tt
    ON tt.transaction_type_key = f.transaction_type_key
GROUP BY d.year_month, tt.transaction_type
ORDER BY d.year_month, tt.transaction_type;

-- Monthly totals help reveal changes in overall transaction volume/value.
SELECT
    d.year_month,
    COUNT(*) AS txns,
    SUM(f.amount_abs) AS gross_value
FROM dw.fact_transaction AS f
JOIN dw.dim_date AS d
    ON d.date_key = f.date_key
GROUP BY d.year_month
ORDER BY d.year_month;

-- Compare average transaction size by calendar month to look for seasonality.
SELECT
    d.month_num,
    d.month_name,
    COUNT(*) AS txns,
    CAST(AVG(f.amount_abs) AS DECIMAL(18, 0)) AS avg_amount
FROM dw.fact_transaction AS f
JOIN dw.dim_date AS d
    ON d.date_key = f.date_key
GROUP BY d.month_num, d.month_name
ORDER BY d.month_num;

/* 10. Transaction count and value by channel */
SELECT
    ch.channel_name,
    COUNT(*) AS txns,
    SUM(f.amount_abs) AS gross_value,
    CAST(AVG(f.amount_abs) AS DECIMAL(18, 0)) AS avg_amount
FROM dw.fact_transaction AS f
JOIN dw.dim_channel AS ch
    ON ch.channel_key = f.channel_key
GROUP BY ch.channel_name
ORDER BY txns DESC;

/* 11. Active customers
   Definition: a customer is active if they made a transaction or had an
   interaction in the 90 days ending 2025-08-31. */
DECLARE @activity_as_of_date DATE = '2025-08-31';

SELECT
    status,
    COUNT(*) AS customers
FROM (
    SELECT
        CASE
            WHEN EXISTS (
                SELECT 1
                FROM dw.fact_transaction AS f
                JOIN dw.dim_date AS d
                    ON d.date_key = f.date_key
                WHERE f.client_key = c.client_key
                  AND d.full_date >= DATEADD(DAY, -90, @activity_as_of_date)
                  AND d.full_date <= @activity_as_of_date
            )
            OR EXISTS (
                SELECT 1
                FROM dw.fact_interaction AS i
                JOIN dw.dim_date AS d
                    ON d.date_key = i.date_key
                WHERE i.client_key = c.client_key
                  AND d.full_date >= DATEADD(DAY, -90, @activity_as_of_date)
                  AND d.full_date <= @activity_as_of_date
            )
            THEN 'Active'
            ELSE 'Not active'
        END AS status
    FROM dw.dim_client AS c
) AS customer_status
GROUP BY status;

/* 12. Top 20 customers by gross transaction value in the latest 12 months */
DECLARE @latest_transaction_date DATE =
    (SELECT latest_txn_date FROM dw.vw_ref);

SELECT TOP (20)
    c.client_number,
    c.first_name,
    c.last_name,
    COUNT(*) AS txns,
    SUM(f.amount_abs) AS gross_value,
    SUM(f.amount) AS net_value
FROM dw.fact_transaction AS f
JOIN dw.dim_date AS d
    ON d.date_key = f.date_key
JOIN dw.dim_client AS c
    ON c.client_key = f.client_key
WHERE d.full_date > DATEADD(MONTH, -12, @latest_transaction_date)
  AND d.full_date <= @latest_transaction_date
GROUP BY c.client_number, c.first_name, c.last_name
ORDER BY gross_value DESC;

/* 13. Average interactions per customer by interaction type */
SELECT
    it.interaction_type,
    COUNT(*) AS interactions,
    COUNT(DISTINCT f.client_key) AS customers_who_used,
    CAST(
        1.0 * COUNT(*) / (SELECT COUNT(*) FROM dw.dim_client)
        AS DECIMAL(6, 3)
    ) AS avg_per_customer
FROM dw.fact_interaction AS f
JOIN dw.dim_interaction_type AS it
    ON it.interaction_type_key = f.interaction_type_key
GROUP BY it.interaction_type
ORDER BY interactions DESC;

/* 14. Complaint channel compared with channels for other interaction types */
SELECT
    ch.channel_name,
    SUM(CASE WHEN it.interaction_type = 'Complaint' THEN 1 ELSE 0 END)
        AS complaints,
    CAST(
        100.0 * SUM(
            CASE WHEN it.interaction_type = 'Complaint' THEN 1 ELSE 0 END
        ) / (
            SELECT COUNT(*)
            FROM dw.fact_interaction AS complaints
            JOIN dw.dim_interaction_type AS complaint_type
                ON complaint_type.interaction_type_key =
                   complaints.interaction_type_key
            WHERE complaint_type.interaction_type = 'Complaint'
        )
        AS DECIMAL(5, 1)
    ) AS pct_of_complaints,
    SUM(CASE WHEN it.interaction_type <> 'Complaint' THEN 1 ELSE 0 END)
        AS other_types,
    CAST(
        100.0 * SUM(
            CASE WHEN it.interaction_type <> 'Complaint' THEN 1 ELSE 0 END
        ) / (
            SELECT COUNT(*)
            FROM dw.fact_interaction AS other_interactions
            JOIN dw.dim_interaction_type AS other_type
                ON other_type.interaction_type_key =
                   other_interactions.interaction_type_key
            WHERE other_type.interaction_type <> 'Complaint'
        )
        AS DECIMAL(5, 1)
    ) AS pct_of_other
FROM dw.fact_interaction AS f
JOIN dw.dim_channel AS ch
    ON ch.channel_key = f.channel_key
JOIN dw.dim_interaction_type AS it
    ON it.interaction_type_key = f.interaction_type_key
GROUP BY ch.channel_name
ORDER BY complaints DESC;

/* 15. Resolution rate by channel
   Unknown outcomes are excluded. margin_pts is an approximate 95% margin. */
WITH resolution_rates AS (
    SELECT
        ch.channel_name,
        COUNT(*) AS known_outcomes,
        1.0 * SUM(CASE WHEN f.resolved_flag = 'Y' THEN 1 ELSE 0 END)
            / COUNT(*) AS resolution_rate
    FROM dw.fact_interaction AS f
    JOIN dw.dim_channel AS ch
        ON ch.channel_key = f.channel_key
    WHERE f.resolved_flag IN ('Y', 'N')
    GROUP BY ch.channel_name
)
SELECT
    channel_name,
    known_outcomes,
    CAST(100 * resolution_rate AS DECIMAL(5, 1)) AS resolution_pct,
    CAST(
        196 * SQRT(
            resolution_rate * (1 - resolution_rate) / known_outcomes
        )
        AS DECIMAL(5, 1)
    ) AS margin_pts
FROM resolution_rates
ORDER BY resolution_pct;

/* 16. Customer value tiers by gross transaction value
   Customers with transactions are split into quartiles; customers without
   transactions are reported separately. */
WITH client_value AS (
    SELECT
        client_key,
        SUM(amount_abs) AS gross_value
    FROM dw.fact_transaction
    GROUP BY client_key
),
value_tiers AS (
    SELECT
        client_key,
        gross_value,
        NTILE(4) OVER (ORDER BY gross_value) AS quartile
    FROM client_value
)
SELECT
    CASE quartile
        WHEN 4 THEN '1 High (top 25%)'
        WHEN 3 THEN '2 Upper-mid'
        WHEN 2 THEN '3 Lower-mid'
        ELSE '4 Low (bottom 25%)'
    END AS tier,
    COUNT(*) AS customers,
    SUM(gross_value) AS total_value,
    MIN(gross_value) AS lowest_in_tier
FROM value_tiers
GROUP BY quartile

UNION ALL

SELECT
    '5 No transactions',
    COUNT(*),
    0,
    0
FROM dw.dim_client AS c
WHERE NOT EXISTS (
    SELECT 1
    FROM dw.fact_transaction AS f
    WHERE f.client_key = c.client_key
)
ORDER BY tier;

/* 17. Customer lifecycle segments
   New = signed up in the last 12 months; Active = activity in 90 days;
   At risk = activity 91-180 days ago; Dormant = older or no activity. */
DECLARE @lifecycle_as_of_date DATE =
    (SELECT latest_event_date FROM dw.vw_ref);

WITH customer_activity AS (
    SELECT
        f.client_key,
        d.full_date
    FROM dw.fact_transaction AS f
    JOIN dw.dim_date AS d
        ON d.date_key = f.date_key

    UNION ALL

    SELECT
        i.client_key,
        d.full_date
    FROM dw.fact_interaction AS i
    JOIN dw.dim_date AS d
        ON d.date_key = i.date_key
),
last_activity AS (
    SELECT
        client_key,
        MAX(full_date) AS last_date
    FROM customer_activity
    WHERE full_date <= @lifecycle_as_of_date
    GROUP BY client_key
)
SELECT
    segment,
    COUNT(*) AS customers
FROM (
    SELECT
        CASE
            WHEN c.signup_date >= DATEADD(MONTH, -12, @lifecycle_as_of_date)
                THEN 'New'
            WHEN a.last_date >= DATEADD(DAY, -90, @lifecycle_as_of_date)
                THEN 'Active'
            WHEN a.last_date >= DATEADD(DAY, -180, @lifecycle_as_of_date)
                THEN 'At risk'
            ELSE 'Dormant'
        END AS segment
    FROM dw.dim_client AS c
    LEFT JOIN last_activity AS a
        ON a.client_key = c.client_key
) AS customer_segments
GROUP BY segment
ORDER BY customers DESC;

/* 18. Compare transaction value across CRM interaction-count groups */
WITH interaction_counts AS (
    SELECT
        client_key,
        COUNT(*) AS interaction_count
    FROM dw.fact_interaction
    GROUP BY client_key
),
transaction_values AS (
    SELECT
        client_key,
        SUM(amount_abs) AS gross_value
    FROM dw.fact_transaction
    GROUP BY client_key
),
customer_summary AS (
    SELECT
        c.client_key,
        ISNULL(i.interaction_count, 0) AS interaction_count,
        ISNULL(v.gross_value, 0) AS gross_value
    FROM dw.dim_client AS c
    LEFT JOIN interaction_counts AS i
        ON i.client_key = c.client_key
    LEFT JOIN transaction_values AS v
        ON v.client_key = c.client_key
)
SELECT
    CASE
        WHEN interaction_count = 0 THEN '0'
        WHEN interaction_count <= 2 THEN '1-2'
        WHEN interaction_count <= 4 THEN '3-4'
        WHEN interaction_count <= 6 THEN '5-6'
        ELSE '7+'
    END AS interaction_band,
    COUNT(*) AS customers,
    CAST(AVG(gross_value) AS DECIMAL(18, 0)) AS avg_txn_value
FROM customer_summary
GROUP BY
    CASE
        WHEN interaction_count = 0 THEN '0'
        WHEN interaction_count <= 2 THEN '1-2'
        WHEN interaction_count <= 4 THEN '3-4'
        WHEN interaction_count <= 6 THEN '5-6'
        ELSE '7+'
    END
ORDER BY MIN(interaction_count);

/* 19. Month-over-month customer retention
   The final month is excluded because the following month is not in the data. */
WITH monthly_activity AS (
    SELECT DISTINCT
        client_key,
        month_start
    FROM (
        SELECT
            f.client_key,
            d.month_start
        FROM dw.fact_transaction AS f
        JOIN dw.dim_date AS d
            ON d.date_key = f.date_key

        UNION ALL

        SELECT
            i.client_key,
            d.month_start
        FROM dw.fact_interaction AS i
        JOIN dw.dim_date AS d
            ON d.date_key = i.date_key
    ) AS activity
)
SELECT
    current_month.month_start,
    COUNT(*) AS active_in_month,
    COUNT(next_month.client_key) AS still_active_next_month,
    CAST(
        100.0 * COUNT(next_month.client_key) / COUNT(*)
        AS DECIMAL(5, 1)
    ) AS retention_pct
FROM monthly_activity AS current_month
LEFT JOIN monthly_activity AS next_month
    ON next_month.client_key = current_month.client_key
   AND next_month.month_start = DATEADD(
       MONTH,
       1,
       current_month.month_start
   )
WHERE current_month.month_start < (
    SELECT MAX(month_start) FROM monthly_activity
)
GROUP BY current_month.month_start
ORDER BY current_month.month_start;

/* 20. Accounts with unusually high daily transaction counts
   These are candidates for review, not proof of fraud. */
SELECT
    a.account_number,
    d.full_date,
    COUNT(*) AS txns,
    SUM(f.amount_abs) AS gross_value
FROM dw.fact_transaction AS f
JOIN dw.dim_account AS a
    ON a.account_key = f.account_key
JOIN dw.dim_date AS d
    ON d.date_key = f.date_key
GROUP BY a.account_number, d.full_date
HAVING COUNT(*) >= 5
ORDER BY txns DESC, gross_value DESC;
