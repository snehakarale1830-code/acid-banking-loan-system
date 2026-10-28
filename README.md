# Intelligent ACID-Compliant Banking & Loan Management System

## 1. How to run
1. Install Python 3 (https://python.org). No other installs needed - the AI model is pure Python.
2. Put `schema.sql` and `bank.py` in one folder and run: `python3 bank.py`
3. It creates `bank.db` (open it with the free "DB Browser for SQLite") and prints the demo.

## 2. What each part of the title means
| Title word | Where it is in the project |
|---|---|
| Banking | `customers`, `accounts`, `transactions` tables; `deposit()`, `transfer()` |
| Loan management | `loans` table; `apply_for_loan()`, EMI formula |
| ACID-compliant | `Tx` class in bank.py + CHECK/FK constraints (see section 4) |
| Trigger-based fraud detection | Triggers T2-T5 in schema.sql, `fraud_alerts` table |
| AI credit-risk assessment | Logistic Regression model, outputs probability of default -> LOW/MEDIUM/HIGH |

## 3. Database design (ER summary)
- CUSTOMER 1 --- N ACCOUNT  (a customer owns many accounts)
- ACCOUNT 1 --- N TRANSACTION (as sender or receiver)
- CUSTOMER 1 --- N LOAN; each LOAN is paid into one ACCOUNT
- TRANSACTION 1 --- N FRAUD_ALERT; ACCOUNT 1 --- N FRAUD_ALERT
- AUDIT_LOG records changes (filled only by triggers)

Normalization: every table has a primary key, each non-key column depends only on
that key (3NF). Customer details are stored once in `customers`, not repeated in accounts/loans.

## 4. ACID mapping (very likely viva question)
- **Atomicity**: `transfer()` does insert-txn + debit + credit inside `BEGIN ... COMMIT`; any error triggers `ROLLBACK`, so half-done transfers never exist. Demo step 2.
- **Consistency**: `CHECK(balance>=0)`, `CHECK(amount>0)`, foreign keys, UNIQUE email. Invalid states are rejected by the DB itself.
- **Isolation**: `BEGIN IMMEDIATE` takes the write lock so two transfers cannot interleave on the same data (SQLite is serializable).
- **Durability**: after COMMIT the data is written to the `bank.db` file (journal/WAL) and survives a crash.

## 5. Triggers
| Trigger | Type | Purpose |
|---|---|---|
| trg_block_inactive_account | BEFORE INSERT | reject txns from frozen accounts |
| trg_fraud_large_amount | AFTER INSERT | amount >= 100000 -> HIGH alert |
| trg_fraud_velocity | AFTER INSERT | 3+ txns in 1 min -> MEDIUM alert |
| trg_fraud_drain | AFTER INSERT | >90% of balance moved -> MEDIUM alert |
| trg_auto_freeze | AFTER INSERT on alerts | 3 alerts -> freeze account |
| trg_audit_balance / status | AFTER UPDATE | audit trail |
| trg_txn_no_update / delete | BEFORE | transactions are immutable |

## 6. AI module
Features: income, loan amount, term, employment years, average balance, number of fraud alerts
(the last one links the fraud system with the AI!). Model: Logistic Regression written from scratch (gradient descent, pure Python) with
standard scaling, trained on synthetic data (real bank data is confidential - say this in your report).
Decision: P(default) < 30% approve, 30-60% manual review, > 60% reject.
Reported metrics: accuracy and ROC-AUC on a 25% test split.

## 7. Report outline (use these headings)
Abstract - Introduction - Problem statement - Objectives - Tools used - ER diagram -
Schema & normalization - ACID implementation - Triggers - AI module - Results (paste the
demo output as screenshots) - Limitations - Future scope - Conclusion.

## 8. Limitations / future scope (examiners like this)
Synthetic training data; SQLite is single-writer (use MySQL/PostgreSQL for real concurrency);
no web UI or login; no repayment schedule table; fraud rules are fixed thresholds
(could add ML anomaly detection).

## 9. Likely viva questions
- What is a trigger? BEFORE vs AFTER? - A procedure the DB runs automatically on INSERT/UPDATE/DELETE.
- What happens if power fails between debit and credit? - Rollback on recovery (atomicity).
- Why CHECK constraint instead of checking in Python? - DB enforces rules for every client.
- Why Logistic Regression? - Simple, explainable, gives probabilities.

## 10. MySQL version (for MySQL Workbench)
Files: `schema_mysql.sql` (tables, triggers, stored procedures, views, AI weights) and `demo_mysql.sql`.
1. Open MySQL Workbench, connect to your local server (needs MySQL 8.0.16+).
2. File > Open SQL Script > `schema_mysql.sql`, click the lightning bolt. Creates database `bank_db`.
3. Open `demo_mysql.sql`; run it step by step (select lines, Ctrl+Shift+Enter).
4. Everything (ACID procedures, fraud triggers, AI scoring) runs inside MySQL. No Python needed.
The AI model is trained by `export_weights.py` (pure Python); its weights are stored in the
`credit_model` table and `sp_apply_loan` computes p = 1/(1+e^-z) in SQL.

## 11. Sample data (MySQL)
Run order in MySQL Workbench: `schema_mysql.sql` -> `sample_data_mysql.sql` -> `demo_mysql.sql`.
`sample_data_mysql.sql` (made by `generate_sample_data.py`) loads 25 customers, 33 accounts, about 230
transactions spread over 3 months, 14 AI-scored loans and 6 fraud alerts (one account is already FROZEN).
Balances are computed from the ledger, so stored balance = deposits + inflows - outflows for every account
(Step 8 of the demo proves it).
