-- =====================================================================
-- Intelligent ACID-Compliant Banking & Loan Management System
-- Schema: tables, constraints, indexes, triggers, views  (SQLite)
-- =====================================================================
PRAGMA foreign_keys = ON;

CREATE TABLE customers (
    customer_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    name             TEXT NOT NULL,
    email            TEXT NOT NULL UNIQUE,
    phone            TEXT,
    monthly_income   REAL NOT NULL CHECK (monthly_income >= 0),
    employment_years REAL NOT NULL DEFAULT 0 CHECK (employment_years >= 0),
    created_at       TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE accounts (
    account_id   INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id  INTEGER NOT NULL REFERENCES customers(customer_id) ON DELETE RESTRICT,
    account_type TEXT NOT NULL CHECK (account_type IN ('SAVINGS','CURRENT')),
    balance      REAL NOT NULL DEFAULT 0 CHECK (balance >= 0),   -- no overdraft (Consistency)
    status       TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','FROZEN','CLOSED')),
    created_at   TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE transactions (
    txn_id       INTEGER PRIMARY KEY AUTOINCREMENT,
    from_account INTEGER REFERENCES accounts(account_id),  -- NULL for deposits / loan disbursal
    to_account   INTEGER REFERENCES accounts(account_id),  -- NULL for withdrawals
    amount       REAL NOT NULL CHECK (amount > 0),
    txn_type     TEXT NOT NULL CHECK (txn_type IN ('TRANSFER','DEPOSIT','WITHDRAWAL','LOAN_DISBURSAL')),
    txn_time     TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (from_account IS NOT NULL OR to_account IS NOT NULL),
    CHECK (from_account IS NULL OR to_account IS NULL OR from_account <> to_account)
);

CREATE TABLE loans (
    loan_id       INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id   INTEGER NOT NULL REFERENCES customers(customer_id),
    account_id    INTEGER NOT NULL REFERENCES accounts(account_id),
    amount        REAL NOT NULL CHECK (amount > 0),
    term_months   INTEGER NOT NULL CHECK (term_months BETWEEN 3 AND 360),
    interest_rate REAL,
    default_prob  REAL,                 -- output of the AI model (0..1)
    risk_band     TEXT CHECK (risk_band IN ('LOW','MEDIUM','HIGH')),
    status        TEXT NOT NULL DEFAULT 'PENDING'
                  CHECK (status IN ('PENDING','APPROVED','REJECTED','MANUAL_REVIEW')),
    applied_at    TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE fraud_alerts (
    alert_id   INTEGER PRIMARY KEY AUTOINCREMENT,
    txn_id     INTEGER NOT NULL REFERENCES transactions(txn_id),
    account_id INTEGER REFERENCES accounts(account_id),
    rule_name  TEXT NOT NULL,
    severity   TEXT NOT NULL CHECK (severity IN ('LOW','MEDIUM','HIGH')),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE audit_log (
    log_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    table_name TEXT NOT NULL,
    record_id  INTEGER,
    action     TEXT NOT NULL,
    old_value  TEXT,
    new_value  TEXT,
    logged_at  TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------- Indexes --------------------------------
CREATE INDEX idx_acc_customer ON accounts(customer_id);
CREATE INDEX idx_txn_from_time ON transactions(from_account, txn_time);
CREATE INDEX idx_alert_account ON fraud_alerts(account_id);
CREATE INDEX idx_loan_customer ON loans(customer_id);

-- ============================ TRIGGERS ===============================

-- T1: Block outgoing transactions from FROZEN / CLOSED accounts
CREATE TRIGGER trg_block_inactive_account
BEFORE INSERT ON transactions
WHEN NEW.from_account IS NOT NULL
 AND (SELECT status FROM accounts WHERE account_id = NEW.from_account) <> 'ACTIVE'
BEGIN
    SELECT RAISE(ABORT, 'Account is frozen or closed: transaction rejected');
END;

-- T2: Fraud rule 1 - unusually large transaction
CREATE TRIGGER trg_fraud_large_amount
AFTER INSERT ON transactions
WHEN NEW.amount >= 100000 AND NEW.txn_type IN ('TRANSFER','WITHDRAWAL')
BEGIN
    INSERT INTO fraud_alerts(txn_id, account_id, rule_name, severity)
    VALUES (NEW.txn_id, NEW.from_account, 'LARGE_AMOUNT (>=100000)', 'HIGH');
END;

-- T3: Fraud rule 2 - velocity (3+ outgoing txns within 1 minute)
CREATE TRIGGER trg_fraud_velocity
AFTER INSERT ON transactions
WHEN NEW.from_account IS NOT NULL
 AND (SELECT COUNT(*) FROM transactions
      WHERE from_account = NEW.from_account
        AND txn_time >= datetime(NEW.txn_time, '-1 minute')) >= 3
BEGIN
    INSERT INTO fraud_alerts(txn_id, account_id, rule_name, severity)
    VALUES (NEW.txn_id, NEW.from_account, 'VELOCITY (3+ txns in 1 min)', 'MEDIUM');
END;

-- T4: Fraud rule 3 - draining >90% of a sizeable balance in one go
--     (balance has already been debited when this runs, see bank.py order,
--      so we compare against balance + amount)
CREATE TRIGGER trg_fraud_drain
AFTER INSERT ON transactions
WHEN NEW.from_account IS NOT NULL AND NEW.amount >= 10000
 AND NEW.amount > 0.9 * (SELECT balance FROM accounts WHERE account_id = NEW.from_account)
BEGIN
    INSERT INTO fraud_alerts(txn_id, account_id, rule_name, severity)
    VALUES (NEW.txn_id, NEW.from_account, 'ACCOUNT_DRAIN (>90% of balance)', 'MEDIUM');
END;

-- T5: Auto-freeze an account after 3 alerts (escalation)
CREATE TRIGGER trg_auto_freeze
AFTER INSERT ON fraud_alerts
WHEN NEW.account_id IS NOT NULL
 AND (SELECT COUNT(*) FROM fraud_alerts WHERE account_id = NEW.account_id) >= 3
BEGIN
    UPDATE accounts SET status = 'FROZEN'
    WHERE account_id = NEW.account_id AND status = 'ACTIVE';
END;

-- T6: Audit every balance change
CREATE TRIGGER trg_audit_balance
AFTER UPDATE OF balance ON accounts
WHEN OLD.balance <> NEW.balance
BEGIN
    INSERT INTO audit_log(table_name, record_id, action, old_value, new_value)
    VALUES ('accounts', NEW.account_id, 'BALANCE_CHANGE', OLD.balance, NEW.balance);
END;

-- T7: Audit account status changes (e.g. freezes)
CREATE TRIGGER trg_audit_status
AFTER UPDATE OF status ON accounts
WHEN OLD.status <> NEW.status
BEGIN
    INSERT INTO audit_log(table_name, record_id, action, old_value, new_value)
    VALUES ('accounts', NEW.account_id, 'STATUS_CHANGE', OLD.status, NEW.status);
END;

-- T8: Transactions are immutable (no UPDATE / DELETE) - financial integrity
CREATE TRIGGER trg_txn_no_update BEFORE UPDATE ON transactions
BEGIN SELECT RAISE(ABORT, 'Transactions are immutable'); END;
CREATE TRIGGER trg_txn_no_delete BEFORE DELETE ON transactions
BEGIN SELECT RAISE(ABORT, 'Transactions cannot be deleted'); END;

-- ============================== VIEWS ================================
CREATE VIEW v_customer_summary AS
SELECT c.customer_id, c.name, COUNT(a.account_id) AS num_accounts,
       COALESCE(SUM(a.balance),0) AS total_balance
FROM customers c LEFT JOIN accounts a ON a.customer_id = c.customer_id
GROUP BY c.customer_id;

CREATE VIEW v_fraud_report AS
SELECT f.alert_id, f.created_at, f.severity, f.rule_name, f.account_id,
       c.name AS customer, t.amount, t.txn_type
FROM fraud_alerts f
JOIN transactions t ON t.txn_id = f.txn_id
JOIN accounts a ON a.account_id = f.account_id
JOIN customers c ON c.customer_id = a.customer_id;
