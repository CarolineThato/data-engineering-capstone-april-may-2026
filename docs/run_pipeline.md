# Run the data pipeline

This guide takes the raw activity file, loads it into SQL Server, prepares
the warehouse tables, and runs the report queries. Think of it as three
steps: copy the source file into the database, clean and organize it, then
ask questions of the finished warehouse.

## Before you start

You need SQL Server, SQL Server Management Studio (SSMS), and the SSIS
project opened in Visual Studio or SSDT. In the SSIS connection managers,
select your own SQL Server instance and the `Customer360_DW` database.

If SSIS shows a "Login timeout expired" error, type `localhost` as the
server name instead of the computer name, then press **Test Connection**.

## One-time database setup

In SSMS, open and run these scripts in order. Connect to the same server
used by the SSIS project:

1. `sql/00_raw_landing.sql` creates the raw landing table.
2. `sql/01_create_dw.sql` creates the staging and warehouse tables.
3. `sql/02_etl_procedures.sql` creates the procedures that clean and load
   the data.

Open a script in SSMS with **File > Open > File**, check the selected
database, and press **Execute (F5)**. Use the same process to run
`sql/03_answers.sql` after loading the warehouse.

`sql/99_reset_dw.sql` is optional. It deletes the staging and warehouse
tables (not the raw table) so you can start again from `01_create_dw.sql`.
You do not need it for a normal run.

## Configure the raw-file load

The incoming file contains text, so land its fields as text first. The
database procedures then check and convert the values in a controlled
step.

1. In SSIS, open the `CM_Raw_Activity_CSV` Flat File connection manager.
   Change **File name** to where `activity_extract.csv` is on your
   computer (the repository copy is in `data/raw`).
2. On the General page, set the code page to **1252 (ANSI - Latin I)** and
   leave Unicode unchecked. This matches the `VARCHAR` landing table and
   avoids the 65001/1252 mismatch error.
3. Still on the General page, set the **header row delimiter to `{LF}`**.
   This file ends each line with a plain line feed, so the default
   `{CR}{LF}` would not find the end of the header row. Tick **Column names
   in the first data row** and keep header rows to skip at 0.
4. On the Advanced page, confirm every column is read as text (`DT_STR`).
   Use width 200 for `email`, 100 for `first_name` and `last_name`, and 50
   for the others.
5. In the Flat File Source, tick **Retain null values from the source as
   null values in the data flow**, so empty fields become database `NULL`
   values.
6. Connect the Flat File Source directly to the OLE DB Destination. Remove
   any Data Conversion component; conversion and validation happen in
   SQL after landing.
7. Refresh the destination mappings and map columns by name. Do not map
   `source_row_id` or `loaded_at`; SQL Server fills those automatically.

## Load the data

Run the SSIS packages in this order:

### 1. `Load_Customer_Activity.dtsx` (raw load)

The package clears `source.customer_activity_extract`, then copies the
file into it. Clearing before loading means that rerunning the package
starts from the same complete source file instead of appending duplicates.
After a run, the data flow should show 21,500 rows.

### 2. `02_Build_DW.dtsx` (warehouse build)

The package runs three Execute SQL Tasks in sequence:

1. `EXEC stg.load_staging;` checks and cleans the source, removes exact
   duplicate lines, and separates enrollments, interactions, and
   transactions.
2. `EXEC dw.load_dimensions;` loads the descriptive warehouse tables.
3. `EXEC dw.load_facts;` loads the event and account records that refer to
   those dimensions.

Keep the success links between these tasks: facts need their dimensions
already in place. If validation fails, the procedure raises an error and
the package turns red rather than reporting a successful but incomplete
load.

## If a run fails

The procedures stop with an error number and a message. The Output window
in Visual Studio (or the Messages tab in SSMS) shows it.

| Error | What it means | What to check |
|---|---|---|
| 50001 | The raw table is empty | Run `Load_Customer_Activity.dtsx` first |
| 50002 | A row has a missing or unknown `event_type` | The file should only contain Product Enrollment, CRM Interaction and Transaction rows |
| 50003 | A date is missing or is not in `yyyy-mm-dd` format | Look for a changed or reformatted date column (for example after the file was opened and saved in Excel) |
| 50004 | A number (amount, balance, credit limit or loan amount) is not numeric | Look for text or symbols in those columns |
| 50030, 50031, 50032 | A fact table has fewer rows than its staging table | Usually an event date outside 2022 to 2026, which the date table does not cover |
| "Violation of PRIMARY KEY" on `stg.client` or `stg.enrollment` | A client or account appears with two different sets of details | Check the source file for conflicting rows for that client or account |

## Check that reruns are safe

Run both packages a second time. These counts should be the same after
each complete run:

```sql
SELECT 'fact_transaction' AS table_name, COUNT(*) AS row_count
FROM dw.fact_transaction
UNION ALL
SELECT 'fact_interaction', COUNT(*)
FROM dw.fact_interaction
UNION ALL
SELECT 'fact_account', COUNT(*)
FROM dw.fact_account
UNION ALL
SELECT 'dim_client', COUNT(*)
FROM dw.dim_client;
```

Expected counts for the supplied extract:

| Table | Rows |
|---|---:|
| `dw.fact_transaction` | 15,000 |
| `dw.fact_interaction` | 4,499 |
| `dw.fact_account` | 2,000 |
| `dw.dim_client` | 1,484 |

Finally, run `sql/03_answers.sql`. It queries only the warehouse tables.

## Why the warehouse has separate tables

The raw file puts several kinds of records in one list. The warehouse
keeps one table for transactions, one for customer interactions, and one
for accounts so that totals from one kind of activity do not accidentally
include another. Customer, date, product, account, and channel details are
stored separately and linked to those records. This keeps common
descriptions consistent and makes the reports easier to check.

Customer details are overwritten when they change (a "Type 1" dimension).
This extract only holds each customer's current details and does not say
when older details were valid, so keeping history would mean inventing it.

The source has no unique ID for transactions or interactions, so the
pipeline avoids duplicates in two ways. Staging removes lines that are
exactly the same, and each warehouse load only adds a row if one with the
same client, date, channel, type and amount is not already there
(`WHERE NOT EXISTS`). Running the pipeline again therefore adds nothing
new.

Transactions whose accounts have no enrollment record are kept. Those
accounts are added to the account table and marked as inferred, instead of
discarding real activity.
