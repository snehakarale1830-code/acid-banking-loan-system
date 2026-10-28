-- =====================================================================
-- Intelligent ACID-Compliant Banking & Loan Management System  (MySQL 8)
-- Run this WHOLE file once in MySQL Workbench (lightning bolt button).
-- It is safe to re-run: it drops and recreates the database.
-- =====================================================================
DROP DATABASE IF EXISTS bank_db;
CREATE DATABASE bank_db;
USE bank_db;

-- ----------------------------- TABLES (InnoDB = ACID engine) ---------
CREATE TABLE customers (
    customer_id      INT AUTO_INCREMENT PRIMARY KEY,
    name             VARCHAR(100) NOT NULL,
    email            VARCHAR(100) NOT NULL UNIQUE,
    phone            VARCHAR(15),
    monthly_income   DECIMAL(12,2) NOT NULL CHECK (monthly_income >= 0),
    employment_years DECIMAL(4,1)  NOT NULL DEFAULT 0 CHECK (employment_years >= 0),
    created_at       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE accounts (
    account_id   INT AUTO_INCREMENT PRIMARY KEY,
    customer_id  INT NOT NULL,
    account_type ENUM('SAVINGS','CURRENT') NOT NULL,
    balance      DECIMAL(15,2) NOT NULL DEFAULT 0 CHECK (balance >= 0),
    status       ENUM('ACTIVE','FROZEN','CLOSED') NOT NULL DEFAULT 'ACTIVE',
    created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id) ON DELETE RESTRICT
) ENGINE=InnoDB;

CREATE TABLE transactions (
    txn_id       INT AUTO_INCREMENT PRIMARY KEY,
    from_account INT NULL,          -- NULL for deposits / loan disbursal
    to_account   INT NULL,          -- NULL for withdrawals
    amount       DECIMAL(15,2) NOT NULL CHECK (amount > 0),
    txn_type     ENUM('TRANSFER','DEPOSIT','WITHDRAWAL','LOAN_DISBURSAL') NOT NULL,
    txn_time     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (from_account) REFERENCES accounts(account_id),
    FOREIGN KEY (to_account)   REFERENCES accounts(account_id),
    CHECK (from_account IS NOT NULL OR to_account IS NOT NULL),
    CHECK (from_account IS NULL OR to_account IS NULL OR from_account <> to_account)
) ENGINE=InnoDB;

CREATE TABLE loans (
    loan_id       INT AUTO_INCREMENT PRIMARY KEY,
    customer_id   INT NOT NULL,
    account_id    INT NOT NULL,
    amount        DECIMAL(15,2) NOT NULL CHECK (amount > 0),
    term_months   INT NOT NULL CHECK (term_months BETWEEN 3 AND 360),
    interest_rate DECIMAL(5,2) NULL,
    default_prob  DECIMAL(6,4) NULL,            -- output of the AI model
    risk_band     ENUM('LOW','MEDIUM','HIGH') NULL,
    status        ENUM('PENDING','APPROVED','REJECTED','MANUAL_REVIEW') NOT NULL DEFAULT 'PENDING',
    applied_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
    FOREIGN KEY (account_id)  REFERENCES accounts(account_id)
) ENGINE=InnoDB;

CREATE TABLE fraud_alerts (
    alert_id   INT AUTO_INCREMENT PRIMARY KEY,
    txn_id     INT NOT NULL,
    account_id INT NULL,
    rule_name  VARCHAR(60) NOT NULL,
    severity   ENUM('LOW','MEDIUM','HIGH') NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (txn_id)     REFERENCES transactions(txn_id),
    FOREIGN KEY (account_id) REFERENCES accounts(account_id)
) ENGINE=InnoDB;

CREATE TABLE audit_log (
    log_id     INT AUTO_INCREMENT PRIMARY KEY,
    table_name VARCHAR(30) NOT NULL,
    record_id  INT,
    action     VARCHAR(30) NOT NULL,
    old_value  VARCHAR(50),
    new_value  VARCHAR(50),
    logged_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- AI model parameters (trained by export_weights.py; used by sp_apply_loan)
CREATE TABLE credit_model (
    feature  VARCHAR(20) PRIMARY KEY,
    mean_val DOUBLE NOT NULL,
    std_val  DOUBLE NOT NULL,
    weight   DOUBLE NOT NULL
) ENGINE=InnoDB;

INSERT INTO credit_model(feature, mean_val, std_val, weight) VALUES
('income', 60353.74491611316, 24169.107798792273, -1.0019710239861284),
('loan_amount', 300434.0851951296, 186864.45934337433, 1.053953116686135),
('term', 50.7328, 38.76403235165299, -1.2722858145274685),
('emp_years', 6.295892678194791, 3.951753652199013, -0.5614451657969138),
('avg_balance', 188658.22486291867, 133142.6790072112, -0.5605009735311745),
('fraud_alerts', 0.29013333333333335, 0.543650606752372, 0.9880171915784494),
('BIAS', 0, 1, -4.20028377450278);

CREATE INDEX idx_acc_customer   ON accounts(customer_id);
CREATE INDEX idx_txn_from_time  ON transactions(from_account, txn_time);
CREATE INDEX idx_alert_account  ON fraud_alerts(account_id);

-- =============================== TRIGGERS ============================
DELIMITER $$

-- T0: no overdraft (works even on old MySQL where CHECK is ignored)
CREATE TRIGGER trg_no_overdraft BEFORE UPDATE ON accounts
FOR EACH ROW
BEGIN
    IF NEW.balance < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient funds: transaction rejected';
    END IF;
END$$

-- T1: block outgoing transactions from FROZEN / CLOSED accounts
CREATE TRIGGER trg_block_inactive_account BEFORE INSERT ON transactions
FOR EACH ROW
BEGIN
    IF NEW.from_account IS NOT NULL AND
       (SELECT status FROM accounts WHERE account_id = NEW.from_account) <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account is frozen or closed: transaction rejected';
    END IF;
END$$

-- T2: Fraud rule 1 - unusually large transaction
CREATE TRIGGER trg_fraud_large_amount AFTER INSERT ON transactions
FOR EACH ROW
BEGIN
    IF NEW.amount >= 100000 AND NEW.txn_type IN ('TRANSFER','WITHDRAWAL') THEN
        INSERT INTO fraud_alerts(txn_id, account_id, rule_name, severity)
        VALUES (NEW.txn_id, NEW.from_account, 'LARGE_AMOUNT (>=100000)', 'HIGH');
    END IF;
END$$

-- T3: Fraud rule 2 - velocity (3+ outgoing txns within 1 minute)
CREATE TRIGGER trg_fraud_velocity AFTER INSERT ON transactions
FOR EACH ROW
BEGIN
    IF NEW.from_account IS NOT NULL AND
       (SELECT COUNT(*) FROM transactions
        WHERE from_account = NEW.from_account
          AND txn_time >= NEW.txn_time - INTERVAL 1 MINUTE) >= 3 THEN
        INSERT INTO fraud_alerts(txn_id, account_id, rule_name, severity)
        VALUES (NEW.txn_id, NEW.from_account, 'VELOCITY (3+ txns in 1 min)', 'MEDIUM');
    END IF;
END$$

-- T4: Fraud rule 3 - moving >90% of a sizeable balance in one go
--     (runs before the debit, so balance is still the pre-transfer balance)
CREATE TRIGGER trg_fraud_drain AFTER INSERT ON transactions
FOR EACH ROW
BEGIN
    IF NEW.from_account IS NOT NULL AND NEW.amount >= 10000 AND
       NEW.amount > 0.9 * (SELECT balance FROM accounts WHERE account_id = NEW.from_account) THEN
        INSERT INTO fraud_alerts(txn_id, account_id, rule_name, severity)
        VALUES (NEW.txn_id, NEW.from_account, 'ACCOUNT_DRAIN (>90% of balance)', 'MEDIUM');
    END IF;
END$$

-- T5: Auto-freeze an account after 3 alerts (escalation)
CREATE TRIGGER trg_auto_freeze AFTER INSERT ON fraud_alerts
FOR EACH ROW
BEGIN
    IF NEW.account_id IS NOT NULL AND
       (SELECT COUNT(*) FROM fraud_alerts WHERE account_id = NEW.account_id) >= 3 THEN
        UPDATE accounts SET status = 'FROZEN'
        WHERE account_id = NEW.account_id AND status = 'ACTIVE';
    END IF;
END$$

-- T6: audit balance and status changes
CREATE TRIGGER trg_audit_account AFTER UPDATE ON accounts
FOR EACH ROW
BEGIN
    IF OLD.balance <> NEW.balance THEN
        INSERT INTO audit_log(table_name, record_id, action, old_value, new_value)
        VALUES ('accounts', NEW.account_id, 'BALANCE_CHANGE', OLD.balance, NEW.balance);
    END IF;
    IF OLD.status <> NEW.status THEN
        INSERT INTO audit_log(table_name, record_id, action, old_value, new_value)
        VALUES ('accounts', NEW.account_id, 'STATUS_CHANGE', OLD.status, NEW.status);
    END IF;
END$$

-- T7: transactions are immutable
CREATE TRIGGER trg_txn_no_update BEFORE UPDATE ON transactions
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transactions are immutable';
END$$

CREATE TRIGGER trg_txn_no_delete BEFORE DELETE ON transactions
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transactions cannot be deleted';
END$$

-- ======================= STORED PROCEDURES (ACID) ====================

-- Deposit
CREATE PROCEDURE sp_deposit(IN p_acc INT, IN p_amt DECIMAL(15,2))
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN ROLLBACK; RESIGNAL; END;
    START TRANSACTION;
        INSERT INTO transactions(to_account, amount, txn_type) VALUES (p_acc, p_amt, 'DEPOSIT');
        UPDATE accounts SET balance = balance + p_amt WHERE account_id = p_acc;
    COMMIT;
END$$

-- Transfer: debit + credit + log happen together or not at all
CREATE PROCEDURE sp_transfer(IN p_src INT, IN p_dst INT, IN p_amt DECIMAL(15,2))
BEGIN
    DECLARE v_lock INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN ROLLBACK; RESIGNAL; END;          -- Atomicity: any error undoes everything
    START TRANSACTION;
        -- Isolation: lock both rows (in id order to avoid deadlock)
        SELECT COUNT(*) INTO v_lock FROM accounts
        WHERE account_id IN (p_src, p_dst) ORDER BY account_id FOR UPDATE;
        INSERT INTO transactions(from_account, to_account, amount, txn_type)
        VALUES (p_src, p_dst, p_amt, 'TRANSFER');                          -- may fire fraud triggers
        UPDATE accounts SET balance = balance - p_amt WHERE account_id = p_src;  -- fails if overdraft
        UPDATE accounts SET balance = balance + p_amt WHERE account_id = p_dst;
    COMMIT;                                  -- Durability
END$$

-- AI helper: one term of the logistic regression = weight * standardised value
CREATE FUNCTION fn_term(p_feature VARCHAR(20), p_value DOUBLE) RETURNS DOUBLE
READS SQL DATA
BEGIN
    DECLARE v DOUBLE;
    SELECT weight * (p_value - mean_val) / std_val INTO v FROM credit_model WHERE feature = p_feature;
    RETURN v;
END$$

-- Loan application: AI scores the customer, decision made, money disbursed atomically
CREATE PROCEDURE sp_apply_loan(IN p_cust INT, IN p_acc INT, IN p_amt DECIMAL(15,2), IN p_term INT)
BEGIN
    DECLARE v_income, v_emp, v_avg, v_alerts, v_z, v_p DOUBLE;
    DECLARE v_band VARCHAR(10);
    DECLARE v_status VARCHAR(15);
    DECLARE v_rate DECIMAL(5,2);
    DECLARE v_loan INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN ROLLBACK; RESIGNAL; END;

    SELECT monthly_income, employment_years INTO v_income, v_emp
    FROM customers WHERE customer_id = p_cust;
    SELECT COALESCE(AVG(balance), 0) INTO v_avg FROM accounts WHERE customer_id = p_cust;
    SELECT COUNT(*) INTO v_alerts FROM fraud_alerts f
    JOIN accounts a ON a.account_id = f.account_id WHERE a.customer_id = p_cust;

    -- logistic regression: p = 1 / (1 + e^-z)
    SELECT weight INTO v_z FROM credit_model WHERE feature = 'BIAS';
    SET v_z = v_z + fn_term('income', v_income) + fn_term('loan_amount', p_amt)
                  + fn_term('term', p_term)     + fn_term('emp_years', v_emp)
                  + fn_term('avg_balance', v_avg) + fn_term('fraud_alerts', v_alerts);
    SET v_p = 1 / (1 + EXP(-GREATEST(-30, LEAST(30, v_z))));

    IF v_p < 0.30 THEN
        SET v_band = 'LOW',    v_status = 'APPROVED',      v_rate = 8.5;
    ELSEIF v_p < 0.60 THEN
        SET v_band = 'MEDIUM', v_status = 'MANUAL_REVIEW', v_rate = 12.0;
    ELSE
        SET v_band = 'HIGH',   v_status = 'REJECTED',      v_rate = NULL;
    END IF;

    START TRANSACTION;      -- loan record + disbursal = one atomic unit
        INSERT INTO loans(customer_id, account_id, amount, term_months, interest_rate,
                          default_prob, risk_band, status)
        VALUES (p_cust, p_acc, p_amt, p_term, v_rate, ROUND(v_p, 4), v_band, v_status);
        SET v_loan = LAST_INSERT_ID();
        IF v_status = 'APPROVED' THEN
            INSERT INTO transactions(to_account, amount, txn_type) VALUES (p_acc, p_amt, 'LOAN_DISBURSAL');
            UPDATE accounts SET balance = balance + p_amt WHERE account_id = p_acc;
        END IF;
    COMMIT;
    SELECT v_loan AS loan_id, ROUND(v_p, 4) AS default_probability, v_band AS risk_band, v_status AS decision;
END$$

DELIMITER ;

-- ================================ VIEWS ==============================
CREATE VIEW v_customer_summary AS
SELECT c.customer_id, c.name, COUNT(a.account_id) AS num_accounts,
       COALESCE(SUM(a.balance), 0) AS total_balance
FROM customers c LEFT JOIN accounts a ON a.customer_id = c.customer_id
GROUP BY c.customer_id, c.name;

CREATE VIEW v_fraud_report AS
SELECT f.alert_id, f.created_at, f.severity, f.rule_name, f.account_id,
       c.name AS customer, t.amount, t.txn_type
FROM fraud_alerts f
JOIN transactions t ON t.txn_id = f.txn_id
JOIN accounts a ON a.account_id = f.account_id
JOIN customers c ON c.customer_id = a.customer_id;
