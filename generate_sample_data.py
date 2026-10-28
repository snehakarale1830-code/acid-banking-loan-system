"""Generates sample_data_mysql.sql (25 customers, ~33 accounts, ~200 txns, loans, fraud alerts).
Balances are computed from the transaction ledger, so everything reconciles."""
import random, datetime as dt
from bank import _synthetic_data, CreditModel
R = random.Random(2026)
X, y = _synthetic_data(); cut = int(len(X) * .75)
model = CreditModel().fit(X[:cut], y[:cut])
F = lambda d: d.strftime("%Y-%m-%d %H:%M:%S")
q = lambda s: "'" + s.replace("'", "''") + "'"

# ---------------- customers
cust = [(1,'Aarav Sharma','aarav@mail.com','9000000001',80000,6),
        (2,'Priya Patil','priya@mail.com','9000000002',30000,1),
        (3,'Rohan Mehta','rohan@mail.com','9000000003',150000,10)]
names = ["Ananya Iyer","Vikram Singh","Sneha Kulkarni","Karan Malhotra","Meera Nair","Arjun Reddy",
 "Pooja Deshmukh","Rahul Verma","Neha Joshi","Aditya Rao","Kavya Menon","Siddharth Jain","Isha Gupta",
 "Manish Patel","Divya Shetty","Rohit Kapoor","Anjali Bhatt","Nikhil Pawar","Shruti Naik","Varun Chopra",
 "Tanvi Gokhale","Harsh Agarwal"]
for i, n in enumerate(names):
    cid = 4 + i; f, l = n.lower().split()
    cust.append((cid, n, f"{f}.{l}@mail.com", f"9000000{cid:03d}", round(R.uniform(20000,190000),-3), round(R.uniform(0,18)*2)/2))
created = {c[0]: dt.datetime(2026,6,1,9) + dt.timedelta(days=R.randint(0,54), hours=R.randint(0,8), minutes=R.randint(0,59)) for c in cust}

# ---------------- accounts: (id, cust, type, opening)
acc = [[1,1,'SAVINGS',500000],[2,2,'SAVINGS',20000],[3,3,'CURRENT',900000]]
aid = 4
for c in cust[3:]:
    op = round(c[4]*(R.uniform(8,15) if c[4] >= 100000 else R.uniform(2,8)), -2)
    acc.append([aid, c[0], R.choice(['SAVINGS','SAVINGS','CURRENT']), op]); aid += 1
for c in R.sample(cust[3:], 8):
    acc.append([aid, c[0], 'CURRENT', round(R.uniform(10000,150000),-2)]); aid += 1
inc = {c[0]: c for c in cust}
first_acc = {}
for a in acc: first_acc.setdefault(a[1], a[0])
rich = sorted([a for a in acc if a[0] >= 4 and a[0] == first_acc[a[1]]], key=lambda a: -inc[a[1]][4])
R1, R2, R3 = rich[0], rich[1], rich[2]
R1[3], R2[3], R3[3] = 900000, 700000, 800000
alerts_of = {R1[1]: 3, R2[1]: 1, R3[1]: 2}
acc_ids = [a[0] for a in acc]; start = dt.datetime(2026,7,30,8)
rt = lambda: start + dt.timedelta(days=R.randint(0,86), hours=R.randint(0,13), minutes=R.randint(0,59), seconds=R.randint(0,59))

# ---------------- loans (decided with the AI model)
loans, events = [], []
for k, c in enumerate(R.sample(cust[3:], 14)):
    term = R.choice([12,24,36,60]); ratio = [0.15,0.45,0.7,1.6][k % 4]
    amt = min(max(round(c[4]*term*ratio, -4), 50000), 2000000)
    ops = [a[3] for a in acc if a[1] == c[0]]
    p = model.predict([c[4], amt, term, c[5], sum(ops)/len(ops), alerts_of.get(c[0], 0)])
    band, status, rate = ("LOW","APPROVED",8.5) if p < .3 else ("MEDIUM","MANUAL_REVIEW",12.0) if p < .6 else ("HIGH","REJECTED",None)
    t = rt(); a_id = first_acc[c[0]]
    loans.append((c[0], a_id, amt, term, rate, round(p,4), band, status, t))
    if status == "APPROVED": events.append(dict(t=t, type='LOAN_DISBURSAL', src=None, dst=a_id, amt=amt, planned=True))

# ---------------- planned fraud scenarios (large transfers >= 100000)
def other(a): return R.choice([x for x in acc_ids if x not in (1,2,3,a)])
for acct, plan in [(R1,[("2026-08-12",120000),("2026-09-03",150000),("2026-09-28",110000)]),
                   (R2,[("2026-09-15",125000)]), (R3,[("2026-08-20",100000),("2026-10-05",140000)])]:
    for d, amt in plan:
        events.append(dict(t=dt.datetime.fromisoformat(d)+dt.timedelta(hours=R.randint(10,16),minutes=R.randint(0,59)),
                           type='TRANSFER', src=acct[0], dst=other(acct[0]), amt=amt, planned=True))
# ---------------- random everyday activity
pool = [x for x in acc_ids if x > 3]
for _ in range(190):
    typ = R.choices(['TRANSFER','DEPOSIT','WITHDRAWAL'], [65,20,15])[0]
    amt = R.randint(5,50)*100 if R.random() < .72 else R.randint(10,90)*1000
    s = R.choice([x for x in pool if x != R1[0]]); d = R.choice([x for x in pool if x != s])
    events.append(dict(t=rt(), type=typ, src=None if typ=='DEPOSIT' else s,
                       dst=None if typ=='WITHDRAWAL' else (d if typ=='TRANSFER' else s), amt=amt, planned=False))

def simulate(evs):
    bal = {a[0]: a[3] for a in acc}; bad = set()
    for i, e in enumerate(sorted(evs, key=lambda e: e['t'])):
        pass
    evs.sort(key=lambda e: e['t'])
    for i, e in enumerate(evs):
        if e['src'] and bal[e['src']] < e['amt']: bad.add(i); continue
        if e['src']: bal[e['src']] -= e['amt']
        if e['dst']: bal[e['dst']] += e['amt']
    return bal, bad

while True:
    bal, bad = simulate(events)
    last = {}
    for i, e in enumerate(events):
        if i in bad: continue
        if e['src'] and e['amt'] >= 10000 and e['amt'] > 0.9 * bal[e['src']]: bad.add(i)
        if e['src']:
            if e['src'] in last and (e['t'] - last[e['src']]).total_seconds() < 180: bad.add(i)
            last[e['src']] = e['t']
    assert not any(events[i]['planned'] for i in bad), "planned event invalid"
    if not bad: break
    events = [e for i, e in enumerate(events) if i not in bad]

# ---------------- write SQL
out = ["-- Sample data for bank_db (generated). Run AFTER schema_mysql.sql, BEFORE demo_mysql.sql.",
       "USE bank_db;", ""]
out.append("INSERT INTO customers(customer_id,name,email,phone,monthly_income,employment_years,created_at) VALUES")
out.append(",\n".join(f"({c[0]},{q(c[1])},{q(c[2])},{q(c[3])},{c[4]},{c[5]},{q(F(created[c[0]]))})" for c in cust) + ";\n")
out.append("INSERT INTO accounts(account_id,customer_id,account_type,balance,status,created_at) VALUES")
out.append(",\n".join(f"({a[0]},{a[1]},'{a[2]}',{bal[a[0]]},'ACTIVE',{q(F(created[a[1]]))})" for a in acc) + ";\n")
rows = [(None, a[0], a[3], 'DEPOSIT', created[a[1]] + dt.timedelta(minutes=5)) for a in acc]
rows += [(e['src'], e['dst'], e['amt'], e['type'], e['t']) for e in events]
rows.sort(key=lambda r: r[4])
n = lambda v: 'NULL' if v is None else str(v)
out.append("INSERT INTO transactions(from_account,to_account,amount,txn_type,txn_time) VALUES")
out.append(",\n".join(f"({n(r[0])},{n(r[1])},{r[2]},'{r[3]}',{q(F(r[4]))})" for r in rows) + ";\n")
out.append("INSERT INTO loans(customer_id,account_id,amount,term_months,interest_rate,default_prob,risk_band,status,applied_at) VALUES")
out.append(",\n".join(f"({l[0]},{l[1]},{l[2]},{l[3]},{n(l[4])},{l[5]},'{l[6]}','{l[7]}',{q(F(l[8]))})" for l in loans) + ";\n")
out.append("-- make alert dates match the transaction dates\n"
           "UPDATE fraud_alerts f JOIN transactions t ON t.txn_id = f.txn_id SET f.created_at = t.txn_time WHERE f.alert_id > 0;\n")
out.append("SELECT 'customers' AS tbl, COUNT(*) AS n FROM customers UNION ALL SELECT 'accounts', COUNT(*) FROM accounts\n"
           "UNION ALL SELECT 'transactions', COUNT(*) FROM transactions UNION ALL SELECT 'loans', COUNT(*) FROM loans\n"
           "UNION ALL SELECT 'fraud_alerts', COUNT(*) FROM fraud_alerts;")
open("sample_data_mysql.sql", "w").write("\n".join(out) + "\n")
print("accounts", len(acc), "txns", len(rows), "loans", len(loans), [l[7] for l in loans])
print("planned freeze account:", R1[0], "alerts_of:", alerts_of)
