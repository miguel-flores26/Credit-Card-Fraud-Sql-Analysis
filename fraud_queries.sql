INSERT INTO transactions_raw 
SELECT * FROM transactions_raw_2;

SELECT COUNT(*) 
FROM transactions_raw;

DROP TABLE transactions_raw_2;

DELETE FROM transactions_raw 
WHERE "Field2" = 'trans_date_trans_time';

SELECT COUNT(*) FROM transactions_raw;

ALTER TABLE transactions_raw RENAME COLUMN "Field1" TO "idx";
ALTER TABLE transactions_raw RENAME COLUMN "Field2" TO "trans_date_trans_time";
ALTER TABLE transactions_raw RENAME COLUMN "Field3" TO "cc_num";
ALTER TABLE transactions_raw RENAME COLUMN "Field4" TO "merchant";
ALTER TABLE transactions_raw RENAME COLUMN "Field5" TO "category";
ALTER TABLE transactions_raw RENAME COLUMN "Field6" TO "amt";
ALTER TABLE transactions_raw RENAME COLUMN "Field7" TO "first_name";
ALTER TABLE transactions_raw RENAME COLUMN "Field8" TO "last_name";
ALTER TABLE transactions_raw RENAME COLUMN "Field9" TO "gender";
ALTER TABLE transactions_raw RENAME COLUMN "Field10" TO "street";
ALTER TABLE transactions_raw RENAME COLUMN "Field11" TO "city";
ALTER TABLE transactions_raw RENAME COLUMN "Field12" TO "state";
ALTER TABLE transactions_raw RENAME COLUMN "Field13" TO "zip";
ALTER TABLE transactions_raw RENAME COLUMN "Field14" TO "lat";
ALTER TABLE transactions_raw RENAME COLUMN "Field15" TO "long";
ALTER TABLE transactions_raw RENAME COLUMN "Field16" TO "city_pop";
ALTER TABLE transactions_raw RENAME COLUMN "Field17" TO "job";
ALTER TABLE transactions_raw RENAME COLUMN "Field18" TO "dob";
ALTER TABLE transactions_raw RENAME COLUMN "Field19" TO "trans_num";
ALTER TABLE transactions_raw RENAME COLUMN "Field20" TO "unix_time";
ALTER TABLE transactions_raw RENAME COLUMN "Field21" TO "merch_lat";
ALTER TABLE transactions_raw RENAME COLUMN "Field22" TO "merch_long";
ALTER TABLE transactions_raw RENAME COLUMN "Field23" TO "is_fraud";

SELECT merchant, COUNT(DISTINCT category) AS c
FROM transactions_raw
GROUP BY merchant
HAVING c > 1;

SELECT COUNT(*) 
FROM (
    SELECT merchant
    FROM transactions_raw
    GROUP BY merchant
    HAVING COUNT(DISTINCT category) > 1
);

SELECT merchant, category, COUNT(*) AS n
FROM transactions_raw
WHERE merchant IN (
    SELECT merchant
    FROM transactions_raw
    GROUP BY merchant
    HAVING COUNT(DISTINCT category) > 1
)
GROUP BY merchant, category
ORDER BY merchant
LIMIT 20;

CREATE TABLE merchants (
    merchant TEXT PRIMARY KEY
);

INSERT INTO merchants
SELECT DISTINCT merchant FROM transactions_raw;

CREATE TABLE customers (
    cc_num      INTEGER PRIMARY KEY,
    first_name  TEXT,
    last_name   TEXT,
    gender      TEXT,
    street      TEXT,
    city        TEXT,
    state       TEXT,
    zip         TEXT,
    lat         REAL,
    long        REAL,
    city_pop    INTEGER,
    job         TEXT,
    dob         TEXT
);

INSERT INTO customers
SELECT DISTINCT
    CAST(cc_num AS INTEGER),
    first_name,
    last_name,
    gender,
    street,
    city,
    state,
    CAST(zip AS TEXT),
    CAST(lat AS REAL),
    CAST(long AS REAL),
    CAST(city_pop AS INTEGER),
    job,
    dob
FROM transactions_raw;

CREATE TABLE transactions (
    trans_num              TEXT PRIMARY KEY,
    cc_num                 INTEGER,
    merchant                TEXT,
    category                TEXT,
    trans_date_trans_time  TEXT,
    amt                     REAL,
    unix_time               INTEGER,
    merch_lat               REAL,
    merch_long               REAL,
    is_fraud                 INTEGER,
    FOREIGN KEY (cc_num) REFERENCES customers(cc_num),
    FOREIGN KEY (merchant) REFERENCES merchants(merchant)
);

INSERT INTO transactions
SELECT
    trans_num,
    CAST(cc_num AS INTEGER),
    merchant,
    category,
    trans_date_trans_time,
    CAST(amt AS REAL),
    CAST(unix_time AS INTEGER),
    CAST(merch_lat AS REAL),
    CAST(merch_long AS REAL),
    CAST(is_fraud AS INTEGER)
FROM transactions_raw;

SELECT COUNT(*) FROM customers;
SELECT COUNT(*) FROM merchants;
SELECT COUNT(*) FROM transactions;

SELECT t.trans_num, t.amt, t.category, t.is_fraud,
       c.first_name, c.last_name, c.job,
       m.merchant
FROM transactions t
JOIN customers c ON t.cc_num = c.cc_num
JOIN merchants m ON t.merchant = m.merchant
LIMIT 10;

WITH customer_baseline AS (
    SELECT
        cc_num,
        COUNT(*)              AS total_transactions,
        AVG(amt)               AS avg_transaction_amt,
        MIN(amt)               AS min_amt,
        MAX(amt)               AS max_amt
    FROM transactions
    GROUP BY cc_num
)
SELECT
    c.first_name,
    c.last_name,
    c.job,
    cb.total_transactions,
    ROUND(cb.avg_transaction_amt, 2) AS avg_spend,
    cb.min_amt,
    cb.max_amt
FROM customer_baseline cb
JOIN customers c ON cb.cc_num = c.cc_num
ORDER BY cb.avg_transaction_amt DESC
LIMIT 20;

-- Query 2b: What fraction of z-score-flagged transactions were actually fraud?
WITH customer_stats AS (
    SELECT
        cc_num,
        AVG(amt) AS avg_amt,
        SQRT(
            SUM((amt - avg_amt_inner) * (amt - avg_amt_inner)) / (COUNT(*) - 1)
        ) AS stddev_amt
    FROM (
        SELECT cc_num, amt, AVG(amt) OVER (PARTITION BY cc_num) AS avg_amt_inner
        FROM transactions
    )
    GROUP BY cc_num
),
flagged AS (
    SELECT
        t.trans_num,
        t.is_fraud,
        (t.amt - cs.avg_amt) / NULLIF(cs.stddev_amt, 0) AS z_score
    FROM transactions t
    JOIN customer_stats cs ON t.cc_num = cs.cc_num
)
SELECT
    COUNT(*) AS total_flagged,
    SUM(is_fraud) AS flagged_that_were_fraud,
    ROUND(100.0 * SUM(is_fraud) / COUNT(*), 2) AS pct_actually_fraud
FROM flagged
WHERE z_score > 3;

-- Overall base fraud rate, for comparison
SELECT ROUND(100.0 * SUM(is_fraud) / COUNT(*), 3) AS overall_fraud_rate_pct
FROM transactions;

SELECT
    category,
    COUNT(*)                                            AS total_transactions,
    SUM(is_fraud)                                        AS fraud_transactions,
    ROUND(100.0 * SUM(is_fraud) / COUNT(*), 3)           AS fraud_rate_pct,
    ROUND(AVG(amt), 2)                                   AS avg_txn_amt,
    ROUND(AVG(CASE WHEN is_fraud = 1 THEN amt END), 2)   AS avg_fraud_amt
FROM transactions
GROUP BY category
ORDER BY fraud_rate_pct DESC;

SELECT
    CAST(strftime('%H', trans_date_trans_time) AS INTEGER) AS hour_of_day,
    COUNT(*)                                    AS total_transactions,
    SUM(is_fraud)                               AS fraud_transactions,
    ROUND(100.0 * SUM(is_fraud) / COUNT(*), 3)  AS fraud_rate_pct
FROM transactions
GROUP BY hour_of_day
ORDER BY hour_of_day;

WITH merchant_category_stats AS (
    SELECT
        merchant,
        category,
        COUNT(*)                                   AS total_transactions,
        SUM(is_fraud)                               AS fraud_transactions,
        ROUND(100.0 * SUM(is_fraud) / COUNT(*), 3)  AS fraud_rate_pct
    FROM transactions
    GROUP BY merchant, category
    HAVING COUNT(*) >= 30
),
ranked AS (
    SELECT
        category,
        merchant,
        total_transactions,
        fraud_transactions,
        fraud_rate_pct,
        RANK() OVER (PARTITION BY category ORDER BY fraud_rate_pct DESC) AS rank_within_category
    FROM merchant_category_stats
)
SELECT *
FROM ranked
WHERE rank_within_category <= 3
ORDER BY category, rank_within_category;

WITH windowed AS (
    SELECT
        trans_num,
        cc_num,
        category,
        is_fraud,
        unix_time,
        COUNT(*) OVER (
            PARTITION BY cc_num
            ORDER BY unix_time
            RANGE BETWEEN 2592000 PRECEDING AND CURRENT ROW
        ) - 1 AS txns_trailing_30d
    FROM transactions
)
SELECT
    category,
    COUNT(*)                                    AS total_transactions,
    SUM(is_fraud)                               AS fraud_transactions,
    ROUND(100.0 * SUM(is_fraud) / COUNT(*), 3)  AS fraud_rate_pct
FROM windowed
WHERE txns_trailing_30d >= 3
GROUP BY category
ORDER BY fraud_rate_pct DESC
LIMIT 10;