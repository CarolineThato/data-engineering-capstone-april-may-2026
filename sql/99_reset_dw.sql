/* ============================================================
   
   ============================================================ */
USE Customer360_DW;
GO
DROP VIEW  IF EXISTS dw.vw_ref;
DROP TABLE IF EXISTS dw.fact_transaction;
DROP TABLE IF EXISTS dw.fact_interaction;
DROP TABLE IF EXISTS dw.fact_account;
DROP TABLE IF EXISTS dw.dim_transaction_type;
DROP TABLE IF EXISTS dw.dim_interaction_type;
DROP TABLE IF EXISTS dw.dim_channel;
DROP TABLE IF EXISTS dw.dim_account;
DROP TABLE IF EXISTS dw.dim_product;
DROP TABLE IF EXISTS dw.dim_client;
DROP TABLE IF EXISTS dw.dim_date;
DROP TABLE IF EXISTS stg.txn;
DROP TABLE IF EXISTS stg.interaction;
DROP TABLE IF EXISTS stg.enrollment;
DROP TABLE IF EXISTS stg.client;
DROP TABLE IF EXISTS stg.dq_issue;
GO
