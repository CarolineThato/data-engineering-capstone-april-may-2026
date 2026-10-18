# Running the pipeline end to end

## Fix for the OLE DB Destination error (code page 65001 and 1252)
The Flat File connection reads the file as UTF-8 (65001) while the destination table columns are VARCHAR (1252). SSIS refuses to mix them.
1. Run `sql/00_raw_landing.sql` in **SQL Server Management Studio (SSMS)**: connect to your server (`DESKTOP-I5L42B8`, as shown in your SSIS connection manager), choose **File > Open > File** to open the script, check the database dropdown says `Customer360_DW`, then press **Execute (F5)**. It recreates `source.customer_activity_extract` with all VARCHAR columns. (The same applies to every `.sql` file in this project.)
2. Double-click the `CM_Raw_Activity_CSV` connection manager, General page: set **Code page = 1252 (ANSI - Latin I)**, leave **Unicode unchecked**, **Text qualifier = "**, **Header rows to skip = 0**, **Column names in the first data row = checked**. The file is pure ASCII, so nothing is lost.
3. Advanced page: every column `DT_STR`, length 200 (email), 100 otherwise.
4. **Delete the Data Conversion component.** Link Flat File Source straight to the OLE DB Destination. All columns land as text; typing happens in SQL where bad values get logged instead of crashing the load.
5. Flat File Source: tick **Retain null values from the source as null values in the data flow**.
6. OLE DB Destination: open it, delete the old mappings (the red X clears once the metadata refreshes; click *Mappings* to refresh), map by name, **do not map `source_row_id` or `loaded_at`** (they are filled by the table).
If the error persists, open Data Conversion output columns on any remaining component and set code page to 1252 there too.

## Packages
**Package 01_Load_Raw**
- Control flow: `Execute SQL Task` (`TRUNCATE TABLE source.customer_activity_extract;`) -> `Data Flow Task` (Flat File Source -> OLE DB Destination, Table or view - fast load).
- Truncating first makes the load re-runnable and keeps `source_row_id` stable.

**Package 02_Build_DW** (three Execute SQL Tasks joined by success constraints)
1. `EXEC stg.load_staging;`  (clean, dedupe, split into stg.enrollment / stg.interaction / stg.txn)
2. `EXEC dw.load_dimensions;`
3. `EXEC dw.load_facts;`
Dimensions must finish before facts; the arrows enforce it. If a procedure THROWs, the package turns red.
Optional extra marks: replace the SQL split with a Conditional Split in package 01 (`event_type == "Transaction"` etc.) writing to the three stg tables.

## One-time setup order
1. Create database `Customer360_DW` (already done).
2. `sql/00_raw_landing.sql`
3. `sql/01_create_dw.sql`
4. `sql/02_etl_procedures.sql`
5. Run package 01, then package 02 (or a parent package that Execute Package Tasks them in order).
6. `sql/03_answers.sql`, compare with the "Expected" comments.

## Re-run test
Run package 01 + 02 twice. Row counts after the second run must be identical:
```sql
SELECT 'fact_transaction',COUNT(*) FROM dw.fact_transaction UNION ALL   -- 15,000
SELECT 'fact_interaction',COUNT(*) FROM dw.fact_interaction UNION ALL   -- 4,499
SELECT 'fact_account',COUNT(*) FROM dw.fact_account UNION ALL           -- 2,000
SELECT 'dim_client',COUNT(*) FROM dw.dim_client;                         -- 1,485 (1,484 + Unknown)
```

## Model (replace the single fact table in your ERD)
Your current diagram has one fact table with six keys plus balances, flags and amounts. That mixes three grains (a balance, a transaction, a CRM contact), so most columns would be NULL on any row and sums can double count. The READMEs also require at least two facts at stated grains. Use:
- `fact_transaction` (1 per transaction): client, account, product, date, channel, transaction_type keys; amount, amount_abs
- `fact_interaction` (1 per CRM interaction): client, date, channel, interaction_type keys; resolved_flag
- `fact_account` (1 per account): client, account, product, enrollment-date keys; credit_limit, loan_amount, account_balance
- Dimensions: dim_date, dim_client (SCD1), dim_product, dim_account, dim_channel, dim_interaction_type, dim_transaction_type
Drop `dim_event` (it only held the event type, which is now the table itself) and move `signup_date` to a date key.

## Design justifications (for the PR)
- SCD1 for clients: the extract is a single current snapshot, no effective dates, so history would be invented.
- `row_hash` + WHERE NOT EXISTS is the idempotency key because the file has no transaction or interaction ID.
- Unknown (-1) members and inferred accounts keep every real event instead of dropping awkward rows.
- Raw layer is all text; typing, trimming and validation happen in staging so failures are visible, not silent.
