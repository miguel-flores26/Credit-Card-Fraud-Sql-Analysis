# Credit-Card-Fraud-Sql-Analysis

## Business Question
Which customer segments and merchant categories show disproportionate fraud risk and how does spending behavior change around fraudulent transactions?

## Dataset
Kaggle's Sparkov-based "Credit Card Transactions Fraud Detection Dataset" 
(kartik2112/fraud-detection). Originally a single flat CSV; normalized 
into `customers`, `merchants`, and `transactions` tables in SQLite.

## Query 1: Customer Spend Baseline
This query establishes each customer's average transaction size and volume before looking into fraud at all. It establishes per-customer spending patterns, which can range from $10-50 to $200+. That baseline matters because a $300 transaction isn't necessarily suspicious for a high spender but may be suspicious for a customer who normally spends $20. Later queries will lean on this baseline for similar observation.

SQL: 
```sql
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
```

## Query 2: Flag Unusual Transactions Relative Customer History
This query flags transactions that are statistical outliers for that specific customer. The z-score above 3 threshold catches the most unusual transactions per customer by their own history. What we want to know now is, what fraction of these flagged spikes were actually fraudulent? This tells us whether a deviation from a customer’s baseline is actually a meaningful fraud signal in this data or simply noise. Of the 25,817 transactions flagged as statistical spikes, 15.85% were actually fraudulent. This is roughly 30 times higher than the overall baseline fraud rate of 0.521%. This confirms that deviation from a customer's own spending patterns is actually a strong fraud signal. While the majority of flagged spikes are still false positives, the signal concentrates risk dramatically compared to looking at transactions with no context at all.

SQL:
```sql
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
        t.cc_num,
        t.trans_date_trans_time,
        t.amt,
        t.category,
        t.is_fraud,
        cs.avg_amt,
        cs.stddev_amt,
        (t.amt - cs.avg_amt) / NULLIF(cs.stddev_amt, 0) AS z_score
    FROM transactions t
    JOIN customer_stats cs ON t.cc_num = cs.cc_num
)
SELECT
    trans_num, cc_num, trans_date_trans_time, amt, category,
    ROUND(avg_amt, 2)   AS customer_avg,
    ROUND(z_score, 2)   AS spend_spike_score,
    is_fraud
FROM flagged
WHERE z_score > 3
ORDER BY z_score DESC;
```
Follow-up: what fraction of flagged spikes were actually fraud?
```sql
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
    SELECT t.trans_num, t.is_fraud,
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
```

## Query 3: Fraud Rate by Merchant Category (Conditional Aggregation)
This query directly answers which merchant categories carry disproportionate risk. The three highest-risk categories were shopping_net (1.593%), misc_net (1.304%), and grocery_pos (1.265%). These each carry rates more than 2.5x the overall baseline of 0.521%. While initial suspicion would suggest a clean online-vs-in-person split fraud split, grocery_pos is a point-of-sale category, yet ranks nearly as high-risk as the online categories. Meanwhile shopping_pos (0.634%)  the in-person counterpart to the riskiest online category sits closer to baseline. This suggests category-level risk in this dataset is driven by something more specific than transaction channel alone which is worth investigating further.

SQL:
```sql
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
```

## Query 4: Fraud Rate by Time of Day 
This query determines whether fraud clusters at certain hours of the day. We can check whether this matches the expected fraud patterns of late night/early morning transactions. Fraud rate spikes sharply during the overnight hours of 10pm–3am. These are the only hours that are above a 1% fraud rate, compared to the baseline 0.521% across all transactions. More drastically, 10-11pm hours saw fraud rates above 2%. This aligns with the pattern in card fraud mentioned previously: stolen cards are often tested during hours when the cardholder is unlikely to notice. A real-time fraud system could apply stricter scrutiny to transactions during this window without inconveniencing genuine spending patterns. This would look like lower approval thresholds and additional verification.

SQL:
```sql
SELECT
    CAST(strftime('%H', trans_date_trans_time) AS INTEGER) AS hour_of_day,
    COUNT(*)                                    AS total_transactions,
    SUM(is_fraud)                               AS fraud_transactions,
    ROUND(100.0 * SUM(is_fraud) / COUNT(*), 3)  AS fraud_rate_pct
FROM transactions
GROUP BY hour_of_day
ORDER BY hour_of_day;
```

## Query 5: Rank Merchants Within Category by Fraud Rate
While category-level fraud rates tell us where risk concentrates broadly, this query tells us which specific merchants are driving that risk within each category. Category-level averages can hide a handful of merchants dragging up an otherwise-normal category so this is information important to consider. Within each category, the top rank merchants run roughly 1.3 to 1.6x higher than that category's overall average fraud rate. Since this was not a dramatic outlier at 5-10x the category average, it suggests that category-level risk in this dataset is fairly broadly distributed across merchants within each category. So the category itself is the primary risk driver and merchant-level ranking here refines that picture slightly rather than overturning it.

SQL:
```sql
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
        category, merchant, total_transactions, fraud_transactions, fraud_rate_pct,
        RANK() OVER (PARTITION BY category ORDER BY fraud_rate_pct DESC) AS rank_within_category
    FROM merchant_category_stats
)
SELECT *
FROM ranked
WHERE rank_within_category <= 3
ORDER BY category, rank_within_category;
```

## Query 6: Top Merchant Categories by Fraud Rate (Customers with 3+ transactions in 30 days)
This query isolates fraud risk among established customers (3+ transactions in their trailing 30 days). If the top categories here differ from Query 3's ranking, it means fraud patterns differ between casual cardholders and regular spenders, which has direct implications for how a real fraud model would need to be segmented by customer activity level, instead of just transaction category alone. Restricting to active customers produces nearly identical category rankings and fraud rates compared to the full population. This can be seen, for example, in categories like shopping_net (1.557% vs. 1.593%), misc_net (1.272% vs. 1.304%), and grocery_pos (1.208% vs. 1.265%) as they all shift by less than half a percentage point. This tells us that category-level fraud risk in this dataset is a stable characteristic of the category itself. Practically, this means a fraud model shouldn't rely on 'new vs dormant account' as a meaningful risk-adjustment factor for category-based rules.

SQL:
```sql
WITH windowed AS (
    SELECT
        trans_num, cc_num, category, is_fraud, unix_time,
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
```

## Overall Summary
Taken together, these queries show that fraud risk in this dataset concentrates around three largely independent factors: merchant category (online/card-not-present categories, and notably grocery_pos, run 2.5–3x the baseline fraud rate), time of day (a clear overnight spike from 10pm–3am, exceeding 2% in the 10–11pm hour), and deviation from a customer's own spending baseline (a ~30x lift over baseline when a transaction is a statistical outlier for that specific person). Risk within a category is fairly evenly distributed across merchants rather than concentrated in a few bad actors, and these category-level patterns hold consistently whether or not the customer is an active, frequent spender. A production fraud model would likely combine all three signals rather than relying on any single one, since each captures a different dimension of risk.
