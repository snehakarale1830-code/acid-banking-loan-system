-- =====================================================================
-- DEMO for MySQL Workbench.  Run schema_mysql.sql FIRST.
-- Run each STEP separately: select its lines, press Ctrl+Shift+Enter.
-- Lines marked "EXPECTED ERROR" are supposed to fail - that is the demo!
-- =====================================================================
USE bank_db;

-- STEP 1: the sample data (25 customers, 33 accounts, ~230 transactions, 14 loans)
-- was loaded by sample_data_mysql.sql. Just look at it:
SELECT * FROM v_customer_summary;
SELECT * FROM accounts WHERE account_id <= 3;      -- the 3 demo accounts
SELECT * FROM v_fraud_report;                      -- fraud caught in the history
SELECT account_id, status FROM accounts WHERE status <> 'ACTIVE';   -- already-frozen account

-- STEP 2: ATOMICITY - a valid transfer
CALL sp_transfer(2, 1, 5000);
SELECT account_id, balance FROM accounts;

-- STEP 2b: EXPECTED ERROR (insufficient funds) - then check nothing changed
CALL sp_transfer(2, 1, 999999);
SELECT account_id, balance FROM accounts;        -- same as before
SELECT COUNT(*) AS txns FROM transactions;       -- failed one was rolled back too

-- STEP 3: FRAUD TRIGGERS - large amount
CALL sp_transfer(3, 1, 150000);

-- STEP 3b: rapid-fire transfers. Select ALL 5 CALL lines + the 2 SELECTs and run together.
-- (Run Step 3 and 3b once each, one right after the other. Do NOT repeat them.)
CALL sp_transfer(1, 3, 100);
CALL sp_transfer(1, 3, 100);
CALL sp_transfer(1, 3, 100);
CALL sp_transfer(1, 3, 100);
CALL sp_transfer(1, 3, 100);
SELECT * FROM v_fraud_report;
SELECT account_id, status FROM accounts;         -- account 1 is now FROZEN

-- STEP 4: EXPECTED ERROR - frozen account is blocked
-- (If this does NOT fail, more than a minute passed: run STEP 3b again, then this.)
CALL sp_transfer(1, 3, 50);
SELECT * FROM audit_log ORDER BY log_id DESC LIMIT 5;

-- STEP 5: EXPECTED ERROR - transactions are immutable
DELETE FROM transactions WHERE txn_id = 1;

-- STEP 6: AI CREDIT RISK (each CALL shows probability, risk band, decision)
CALL sp_apply_loan(3, 3, 400000, 60);
CALL sp_apply_loan(1, 1, 600000, 36);
CALL sp_apply_loan(2, 2, 900000, 12);
SELECT * FROM loans;

-- STEP 7: analytics
SELECT * FROM v_customer_summary;
SELECT risk_band, COUNT(*) AS loans, SUM(amount) AS total FROM loans GROUP BY risk_band;
SELECT name FROM customers WHERE customer_id IN
  (SELECT a.customer_id FROM accounts a JOIN fraud_alerts f ON f.account_id = a.account_id);

-- STEP 8 (bonus): RECONCILIATION - stored balance must equal the ledger (deposits + inflows - outflows)
SELECT a.account_id, a.balance AS stored_balance,
       COALESCE(SUM(CASE WHEN t.to_account   = a.account_id THEN t.amount END),0)
     - COALESCE(SUM(CASE WHEN t.from_account = a.account_id THEN t.amount END),0) AS ledger_balance
FROM accounts a LEFT JOIN transactions t ON t.to_account = a.account_id OR t.from_account = a.account_id
GROUP BY a.account_id, a.balance;                  -- the two columns match on every row
