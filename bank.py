"""
Intelligent ACID-Compliant Banking & Loan Management System
Run:  python3 bank.py          (runs the full demo)
Needs: only Python 3 (sqlite3, math, random are all built in - nothing to install)
"""
import os, sqlite3, math, random

DB = "bank.db"
HERE = os.path.dirname(os.path.abspath(__file__))


# ------------------------------------------------------------------ DB setup
def connect(fresh=False):
    path = os.path.join(HERE, DB)
    if fresh and os.path.exists(path):
        os.remove(path)
    new = not os.path.exists(path)
    # isolation_level=None -> we control BEGIN/COMMIT/ROLLBACK ourselves
    conn = sqlite3.connect(path, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    if new:
        conn.executescript(open(os.path.join(HERE, "schema.sql")).read())
    return conn


class Tx:
    """Context manager = one ACID transaction. Commits on success, rolls back on ANY error."""
    def __init__(self, conn): self.conn = conn
    def __enter__(self):
        self.conn.execute("BEGIN IMMEDIATE")   # take write lock -> Isolation
        return self.conn
    def __exit__(self, exc_type, exc, tb):
        if exc_type: self.conn.execute("ROLLBACK")   # Atomicity
        else:        self.conn.execute("COMMIT")     # Durability
        return False


# ------------------------------------------------------------ Core banking
def add_customer(conn, name, email, phone, income, emp_years):
    with Tx(conn):
        cid = conn.execute(
            "INSERT INTO customers(name,email,phone,monthly_income,employment_years) VALUES(?,?,?,?,?)",
            (name, email, phone, income, emp_years)).lastrowid
    return cid

def open_account(conn, customer_id, acc_type="SAVINGS", initial=0.0):
    with Tx(conn):
        return conn.execute(
            "INSERT INTO accounts(customer_id,account_type,balance) VALUES(?,?,?)",
            (customer_id, acc_type, initial)).lastrowid

def deposit(conn, acc, amount):
    with Tx(conn):
        conn.execute("INSERT INTO transactions(to_account,amount,txn_type) VALUES(?,?,'DEPOSIT')", (acc, amount))
        conn.execute("UPDATE accounts SET balance = balance + ? WHERE account_id=?", (amount, acc))

def transfer(conn, src, dst, amount):
    """Money transfer: both the debit and credit happen, or neither does."""
    with Tx(conn):
        # 1) log txn first: BEFORE-trigger blocks frozen accounts
        conn.execute("INSERT INTO transactions(from_account,to_account,amount,txn_type) VALUES(?,?,?,'TRANSFER')",
                     (src, dst, amount))
        # 2) debit: CHECK(balance>=0) fails if insufficient funds -> whole tx rolls back
        conn.execute("UPDATE accounts SET balance = balance - ? WHERE account_id=?", (amount, src))
        # 3) credit
        conn.execute("UPDATE accounts SET balance = balance + ? WHERE account_id=?", (amount, dst))

def balance(conn, acc):
    return conn.execute("SELECT balance FROM accounts WHERE account_id=?", (acc,)).fetchone()[0]


# ------------------------------------------------- AI credit-risk model
# Logistic Regression implemented FROM SCRATCH (gradient descent), pure Python.
FEATURES = ["income", "loan_amount", "term", "emp_years", "avg_balance", "fraud_alerts"]

def _poisson(rng, lam):
    L, k, p = math.exp(-lam), 0, 1.0
    while True:
        p *= rng.random()
        if p <= L: return k
        k += 1

def _synthetic_data(n=2500, seed=42):
    """Synthetic loan history. Default risk rises with EMI-to-income ratio and fraud flags."""
    r = random.Random(seed)
    X, y = [], []
    for _ in range(n):
        income  = min(max(r.gauss(60000, 25000), 10000), 250000)
        loan    = min(max(r.gauss(300000, 200000), 10000), 2_000_000)
        term    = r.choice([12, 24, 36, 60, 120])
        emp     = min(r.gammavariate(2.5, 2.5), 35)
        avg_bal = income * r.uniform(0.2, 6)
        alerts  = _poisson(r, 0.3)
        emi_ratio = (loan / term) / income
        z = (-1.0 + 2.5 * emi_ratio - 0.08 * emp - 0.6 * math.log1p(avg_bal / income)
             + 0.9 * alerts + r.gauss(0, 0.6))
        X.append([income, loan, term, emp, avg_bal, alerts])
        y.append(1 if z > 0.2 else 0)       # 1 = defaulted
    return X, y

def _sigmoid(z):
    z = max(min(z, 30), -30)
    return 1 / (1 + math.exp(-z))

class CreditModel:
    """Standardise features, then fit weights w and bias b by gradient descent on log-loss."""
    def fit(self, X, y, epochs=300, lr=0.5):
        n, d = len(X), len(X[0])
        self.mu = [sum(row[j] for row in X) / n for j in range(d)]
        self.sd = [math.sqrt(sum((row[j] - self.mu[j]) ** 2 for row in X) / n) or 1 for j in range(d)]
        Z = [self._scale(row) for row in X]
        self.w, self.b = [0.0] * d, 0.0
        for _ in range(epochs):
            gw, gb = [0.0] * d, 0.0
            for zi, yi in zip(Z, y):
                err = _sigmoid(sum(w * v for w, v in zip(self.w, zi)) + self.b) - yi
                for j in range(d): gw[j] += err * zi[j]
                gb += err
            self.w = [w - lr * g / n for w, g in zip(self.w, gw)]
            self.b -= lr * gb / n
        return self
    def _scale(self, row):
        return [(v - m) / s for v, m, s in zip(row, self.mu, self.sd)]
    def predict(self, row):
        """Probability of default for one applicant (list of 6 feature values)."""
        return _sigmoid(sum(w * v for w, v in zip(self.w, self._scale(row))) + self.b)

def _auc(y, p):
    """ROC-AUC = chance a random defaulter is scored higher than a random non-defaulter."""
    pos = [pi for pi, yi in zip(p, y) if yi == 1]
    neg = [pi for pi, yi in zip(p, y) if yi == 0]
    wins = sum((a > b) + 0.5 * (a == b) for a in pos[:300] for b in neg[:300])
    return wins / (len(pos[:300]) * len(neg[:300]))

def train_model():
    X, y = _synthetic_data()
    cut = int(len(X) * 0.75)                       # 75% train / 25% test
    model = CreditModel().fit(X[:cut], y[:cut])
    p = [model.predict(r) for r in X[cut:]]
    acc = sum((pi > .5) == bool(yi) for pi, yi in zip(p, y[cut:])) / len(p)
    print(f"[AI] Credit model trained: accuracy={acc:.2f}  ROC-AUC={_auc(y[cut:], p):.2f}  "
          f"default rate={sum(y)/len(y):.0%}")
    return model

def apply_for_loan(conn, model, customer_id, account_id, amount, term):
    """Score the applicant with the model; decide; disburse money atomically if approved."""
    cust = conn.execute("SELECT * FROM customers WHERE customer_id=?", (customer_id,)).fetchone()
    avg_bal = conn.execute("SELECT COALESCE(AVG(balance),0) FROM accounts WHERE customer_id=?",
                           (customer_id,)).fetchone()[0]
    n_alerts = conn.execute("""SELECT COUNT(*) FROM fraud_alerts f JOIN accounts a ON a.account_id=f.account_id
                               WHERE a.customer_id=?""", (customer_id,)).fetchone()[0]
    x = [cust["monthly_income"], amount, term, cust["employment_years"], avg_bal, n_alerts]
    pd_ = model.predict(x)

    if   pd_ < 0.30: band, status, rate = "LOW",    "APPROVED",      8.5
    elif pd_ < 0.60: band, status, rate = "MEDIUM", "MANUAL_REVIEW", 12.0
    else:            band, status, rate = "HIGH",   "REJECTED",      None

    with Tx(conn):   # loan record + disbursal = one atomic unit
        lid = conn.execute("""INSERT INTO loans(customer_id,account_id,amount,term_months,interest_rate,
                              default_prob,risk_band,status) VALUES(?,?,?,?,?,?,?,?)""",
                           (customer_id, account_id, amount, term, rate, round(pd_, 4), band, status)).lastrowid
        if status == "APPROVED":
            conn.execute("INSERT INTO transactions(to_account,amount,txn_type) VALUES(?,?,'LOAN_DISBURSAL')",
                         (account_id, amount))
            conn.execute("UPDATE accounts SET balance = balance + ? WHERE account_id=?", (amount, account_id))
    return lid, pd_, band, status

def emi(amount, rate, months):
    r = rate / 1200
    return amount * r * (1 + r) ** months / ((1 + r) ** months - 1)


# --------------------------------------------------------------- Demo
def show(conn, title, sql, args=()):
    print(f"\n--- {title} ---")
    rows = conn.execute(sql, args).fetchall()
    if not rows: print("(no rows)"); return
    print(" | ".join(rows[0].keys()))
    for r in rows: print(" | ".join(str(v) for v in tuple(r)))

def demo():
    conn = connect(fresh=True)
    model = train_model()

    print("\n=== 1. Setup customers & accounts ===")
    a = add_customer(conn, "Aarav Sharma", "aarav@mail.com", "9000000001", 80000, 6)
    b = add_customer(conn, "Priya Patil",  "priya@mail.com",  "9000000002", 30000, 1)
    c = add_customer(conn, "Rohan Mehta",  "rohan@mail.com",  "9000000003", 150000, 10)
    acc_a = open_account(conn, a, "SAVINGS", 500000)
    acc_b = open_account(conn, b, "SAVINGS", 20000)
    acc_c = open_account(conn, c, "CURRENT", 900000)
    print("Accounts created:", acc_a, acc_b, acc_c)

    print("\n=== 2. ATOMICITY & CONSISTENCY ===")
    transfer(conn, acc_a, acc_b, 5000)
    print("Valid transfer 5000: A =", balance(conn, acc_a), " B =", balance(conn, acc_b))
    try:
        transfer(conn, acc_b, acc_a, 999999)       # insufficient funds
    except sqlite3.Error as e:
        print("Overdraft transfer FAILED ->", e)
    print("After failed transfer (unchanged!): A =", balance(conn, acc_a), " B =", balance(conn, acc_b))
    n = conn.execute("SELECT COUNT(*) FROM transactions").fetchone()[0]
    print("Transactions logged (failed one rolled back too):", n)

    print("\n=== 3. FRAUD DETECTION TRIGGERS ===")
    transfer(conn, acc_c, acc_a, 150000)           # large amount -> HIGH alert
    for _ in range(3):                              # rapid-fire -> velocity alert
        transfer(conn, acc_a, acc_c, 100)
    show(conn, "Fraud report (view)", "SELECT alert_id,severity,rule_name,account_id,customer,amount FROM v_fraud_report")
    show(conn, "Account status after alerts", "SELECT account_id,status FROM accounts")

    print("\n=== 4. Auto-freeze blocks further transactions ===")
    try:
        for _ in range(3): transfer(conn, acc_a, acc_c, 50)
    except sqlite3.Error as e:
        print("Blocked ->", e)
    show(conn, "Accounts", "SELECT account_id,status,balance FROM accounts")
    show(conn, "Audit log (last 5)", "SELECT * FROM audit_log ORDER BY log_id DESC LIMIT 5")

    print("\n=== 5. Immutability trigger ===")
    try: conn.execute("DELETE FROM transactions WHERE txn_id=1")
    except sqlite3.Error as e: print("DELETE blocked ->", e)

    print("\n=== 6. AI CREDIT RISK ASSESSMENT ===")
    for cid, acc, amt, term in [(c, acc_c, 400000, 60), (a, acc_a, 600000, 36), (b, acc_b, 900000, 12)]:
        lid, p, band, st = apply_for_loan(conn, model, cid, acc, amt, term)
        print(f"Loan #{lid} customer {cid}: amount={amt} term={term}m -> P(default)={p:.1%} risk={band} => {st}")
    show(conn, "Loans", "SELECT loan_id,customer_id,amount,default_prob,risk_band,status,interest_rate FROM loans")
    print(f"\nEMI for 400000 @8.5% over 60 months = {emi(400000, 8.5, 60):.2f}")

    print("\n=== 7. Analytics queries ===")
    show(conn, "Customer summary (view)", "SELECT * FROM v_customer_summary")
    show(conn, "Total money by risk band", "SELECT risk_band, COUNT(*) loans, SUM(amount) total FROM loans GROUP BY risk_band")
    show(conn, "Customers with fraud alerts (subquery)",
         "SELECT name FROM customers WHERE customer_id IN (SELECT a.customer_id FROM accounts a JOIN fraud_alerts f ON f.account_id=a.account_id)")
    print("\nDone. Database file: bank.db (open it in 'DB Browser for SQLite' to explore).")

if __name__ == "__main__":
    demo()
