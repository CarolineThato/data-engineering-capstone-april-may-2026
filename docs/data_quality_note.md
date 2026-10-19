# Data quality note

## About the file

`activity_extract.csv` has 21,500 rows and 23 columns. Each row is one
event: 2,000 product enrollments, 4,500 CRM interactions and 15,000
transactions. The file covers 1,484 different clients. I checked the file
before designing the warehouse, and the design follows what I found.

## Why the warehouse is designed this way

The source file mixes customer details, account signups, conversations with
the bank, and money movements in one long list. The warehouse separates
these into clear tables so that a report about transactions cannot
accidentally count conversations or account balances as transactions.
Each activity table has one row per real-world event or account.

Customer information is stored once rather than repeated on every event.
The source only gives us each customer's current details, not a history of
changes, so the warehouse keeps the current details and overwrites them if
they change. Keeping a history would mean inventing it.

Accounts that have transactions but no signup record are kept and marked as
inferred. Dropping them would hide real money movements. Transaction
amounts keep their original plus and minus signs. Reports use the absolute
amount when they need the total size of transactions, so that deposits and
withdrawals do not cancel each other out.

Data is first landed as text, then checked and converted in a later step.
This makes unexpected values visible and stops a bad value from being
silently mistaken for a valid one.

## Problems found and what I did

| # | What I found | How many | What I did and why |
|---|---|---|---|
| 1 | One row appears twice with every field the same (client CL00813, a CRM "Query" interaction) | 1 row | Removed the extra copy during staging. The file has no record ID, and every field matches, so it is a repeated line and not a second event. |
| 2 | Email is blank | 29 clients | Kept as empty and marked `Missing`. I did not make up a value. |
| 3 | Email has spaces at the start or end, or capital letters | 134 clients with spaces, 208 with capitals | Removed the spaces and made the email lower case. This is safe because it does not change the address. |
| 4 | Email has a space inside it, for example `sam.de villiers82@webmail.co.za` | 134 clients | Marked `Invalid` and kept the value as it is. I cannot know what the correct address is. |
| 5 | The same email is used by two different client numbers, for example `grace.zulu36@yahoo.com` on CL00690 and CL01110 | 16 clients (8 pairs) | Marked with `duplicate_email_flag` and did not merge them. Their names, birth dates and phone numbers differ, so I cannot tell a mistake from a real shared address. Someone should review them. |
| 6 | Mobile number is blank | 113 clients | Kept as empty. |
| 7 | Mobile numbers are written in five ways: `0821234567` (636), `+27821234567` (299), `27821234567` (161), `082-123-4567` (140) and `082 123 4567` (135) | 1,371 clients | Changed all of them to `+27821234567`, so the same number is always written the same way. |
| 8 | Gender is blank or `U` | 67 blank and 41 `U`, so 108 clients | Changed both to `Unknown`. I do not count this as a quality problem, because the value is allowed to be unknown. |
| 9 | Transactions on accounts that have no enrollment row (account numbers starting `AC9`) | 10 transactions on 10 accounts | Kept them. I added the accounts to the account table, marked them `is_inferred = 1` with status `Unknown`. Deleting them would remove real money movement. |
| 10 | Amounts are signed. Money out is negative (Debit Order, Fee, POS Purchase, Withdrawal) and money in is positive (Deposit, EFT Payment, Refund) | all 15,000 transactions | Stored the amount with its sign in `amount`, and added `amount_abs` for the size. Questions about "transaction value" use `amount_abs`, because the signed total is close to zero. |
| 11 | Transactions with an amount of exactly 0 | 26 transactions | Kept them. I cannot tell whether they are errors, and they do not change any totals. |
| 12 | `resolved_flag` is blank on some CRM interactions | 217 of 4,499 | Stored as `U` (unknown) and left out when working out resolution rates. |
| 13 | Closed accounts still have balances | 312 closed accounts, average balance about 22,370 | Kept them. Questions about holding a product use accounts that are not closed. Where it matters, I show the all-accounts figure next to it. |
| 14 | Some clients have no enrollment or no transactions | 230 with no enrollment, 231 with no transactions | Kept them as customers. They fall into the "no activity" groups in the reports. |
| 15 | The extract is uneven over time. Transactions grow from 8 in April 2022 to 3,019 in August 2025, then drop to between 2 and 11 a month until January 2026. CRM activity stops the same way. Signups end on 2025-06-28. | whole file | Nothing to fix, but it affects the reports. The latest date in the data (2026-02-21) is set by a few rows, so for questions about recent activity (Q11 and Q17) I show the result at 2026-02-21 and at 2025-08-31. The monthly pattern in Q9 is growth, not seasonality, because the average amount is about 4,000 in every month. |

## Checked and found no problem

- Every date is in `yyyy-mm-dd` format.
- No event happens before the client signed up.
- Each client has the same details on every row.
- Each city belongs to only one province.
- Every amount, balance, credit limit and loan amount is a number.
- Every row is one of the three event types.

## How the pipeline protects the data

The load stops with an error if the raw table is empty, an event type is
unknown, a date or number cannot be read, or a fact table has fewer rows
than its staging table. It also stops if one client or account appears with
two different sets of details. This means a bad file fails loudly instead of
loading wrong data quietly. Running the pipeline again does not duplicate
rows, because staging is rebuilt each time and the warehouse loads only add
rows that are not already there.
