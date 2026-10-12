# Methodology

This page records every definition, cleaning decision and exclusion used in the analysis, with its effect on row counts.
Each number is reproduced by the SQL files and saved in [reports/sql_results/](../reports/sql_results/).

## 1. Pipeline

```
data/raw/*.csv  (never modified)
   │  sql/01_create_schema.sql      typed staging tables raw_*
   │  sql/02_load_and_validate.sql  @load CSV -> raw_* (Python csv module), key indexes,
   │                                row counts, stored types, keys, FK coverage, timestamp checks
   ▼
raw_*  (9 tables, exact copies of the CSVs)          data/processed/olist.db (SQLite)
   │  sql/03_transform.sql          dimensions, facts, bridges + post-join checks
   ▼
fct_* / dim_* / bridges (star schema) ─► sql/04_business_analysis.sql  (Q1–Q9)
   │                                   ─► sql/05_headline_metrics.sql  (reconciliation targets)
   │                                   ─► notebooks/01_delivery_and_reviews.ipynb (independent validation + EDA)
   ▼
data/processed/*.csv  ─► Power BI semantic model (powerbi/pbip -> powerbi/delivery_reviews.pbix)
```

`scripts/build_database.py` uses only Python's standard library (`sqlite3`, `csv`, `json`). It recreates `data/processed/olist.db` and runs the five SQL files in order (about 3–4 minutes). **The build stops if any `@check` fails.** Checks cover raw row counts, stored types and timestamp formats, key uniqueness, referential integrity, row counts preserved through joins, BRL totals preserved after aggregation, and region mapping. It then compares the headline metrics with the validated baseline (§8) and exports the model tables to CSV for Power BI.

**Engine: SQLite.** SQLite runs inside Python with no server, credentials or extra driver. It has no schemas, so the layers are separated by name: `raw_*` for staging, and `fct_*`, `dim_*`, `stg_*` and the bridges for the analysis layer. Other SQLite specifics:
* SQLite has no `COPY`. The `-- @load:` steps in `02_load_and_validate.sql` are executed by the runner, which streams each CSV into its table (empty cell → NULL; the header must match the table's columns; the translation file's byte-order mark is stripped).
* Types are dynamic, so `02` checks that every value landed with its declared type and that every timestamp has the exact `YYYY-MM-DD HH:MM:SS` shape. ISO text then compares chronologically, and `date()`, `strftime()` and `unixepoch()` work on it.
* Flags are INTEGER 1/0 (NULL = not applicable). Durations are `unixepoch()` differences in whole seconds, then `/ 86400.0`.
* There is no `MEDIAN` or `PERCENTILE_CONT`. Percentiles are computed in SQL with `ROW_NUMBER()`/`COUNT()` windows using linear interpolation: position = p·(n−1), value = v[floor] + fraction·(v[floor+1] − v[floor]). That is the same definition as `PERCENTILE_CONT`, pandas' default quantile and DAX `MEDIAN`/`PERCENTILEX.INC`.
* Rankings `ORDER BY` the unrounded metric plus an ID tie-breaker, so equal displayed values sort deterministically and in true order.

## 2. Grain discipline

* `orders` is the order grain. `order_items`, `order_payments` and `order_reviews` are one-to-many to orders.
* A naive `orders × items` join produces 113,425 rows for 99,441 orders (+13,984 duplicate order rows). The notebook demonstrates this.
* Rule applied: **aggregate each one-to-many table to `order_id` first, then join** (`items_per_order`, `payments_per_order`, `stg_order_review`). Checks confirm `fct_orders` has exactly 99,441 rows, and that Σ item value (R$ 15,843,553.24) and Σ payments (R$ 16,008,872.12) are unchanged.
* Seller and category metrics use bridge tables at (order, seller) and (order, category) grain, because the delivery date exists only at order level. 1,278 orders (1.3%) have more than one seller and 786 (0.8%) more than one category. Those orders count once in each group, and the order's single delivery outcome applies to all of them.
* Shipping lanes (seller state → customer state) use one row per (order, lane): an order shipped by two sellers from the same state counts once in that lane. The Power BI `Lane` column uses the same definition.
* In Power BI, order measures count rows of `fct_orders`. Item and category filters reach it through a bidirectional `fct_orders ↔ fct_order_items` relationship, so orders are never double-counted.

## 3. Metric definitions

| Metric | Grain | Numerator | Denominator / population | Notes |
|---|---|---|---|---|
| Delivery-KPI population | order | n/a | status = `delivered` **and** delivery timestamp present: **96,470** | 2,971 orders excluded (see §4) |
| Late-delivery rate (primary) | order | delivery **date** > estimated **date** | delivery-KPI orders | 6,534 / 96,470 = 6.77% |
| Late-delivery rate (sensitivity) | order | delivery timestamp > estimated timestamp | delivery-KPI orders | 7,826 / 96,470 = 8.11% |
| Lifecycle stage duration | order | timestamp difference | delivery-KPI orders whose two stage timestamps exist and are in order | median, p75, p90 reported; means are skewed |
| Average review score | order | Σ score | delivery-KPI orders with a review | one review per order |
| Canceled / unavailable share | order | status canceled or unavailable | **all** orders | 1,234 / 99,441 = 1.24% |
| Order value (BRL) | order | Σ price + Σ freight | delivered orders | gross merchandise value, **not profit or Olist revenue** |
| Excess late orders | group | late orders − delivered orders × marketplace late rate | groups above a minimum volume | combines rate and volume for prioritisation |
| Wilson lower bound | group | 95% lower confidence bound of the late rate | groups above a minimum volume | conservative rate that penalises small samples |
| Carrier hand-off late | order | carrier date > latest item `shipping_limit_date` | delivery-KPI orders with a carrier date | seller-side signal |

### Why the late definition was adapted
The brief defines late as *"actual customer delivery timestamp later than estimated delivery timestamp."* In the actual file, **every one of the 99,441 estimated delivery values is at 00:00:00**, so it is a date. A literal timestamp comparison marks an order delivered at 15:00 on the promised day as late, which affects 1,292 orders. The primary metric therefore compares calendar dates. The literal rule is kept as `is_late_timestamp_rule` and reported alongside (8.11% vs 6.77%). Conclusions don't change under either rule.

## 4. Exclusions by KPI

| KPI | Included | Excluded | Reason |
|---|---:|---:|---|
| Late rate, delivery durations | 96,470 | 1,107 shipped · 625 canceled · 609 unavailable · 314 invoiced · 301 processing · 5 created · 2 approved · **8 delivered without a delivery date** | not delivered, or no delivery timestamp |
| Purchase → approval | 96,456 | 14 | approval timestamp missing |
| Approval → carrier | 95,105 | 1,365 | approval timestamp missing (14), carrier timestamp missing (1), or carrier earlier than approval (1,350) |
| Carrier → customer | 96,446 | 24 | carrier timestamp missing (1) or delivery earlier than carrier hand-off (23) |
| All three stages valid | 95,082 | 1,388 | union of the above |
| Review comparisons | 95,824 | 646 | delivered orders without a review |
| Monthly trends | Jan-2017 → Aug-2018 | 329 orders before 2017, 20 orders from Sep-2018 | partial or sparse months |

## 5. Cleaning decisions and their effect on rows

| # | Decision | Effect |
|---|---|---|
| 1 | Raw files loaded unchanged; cleaning happens only in the analysis tables (`fct_*`, `dim_*`) | 0 rows altered in `raw_*` |
| 2 | Keep all orders in `fct_orders`, use flags instead of deleting rows | 99,441 → 99,441 |
| 3 | One review per order: most recently answered | 99,224 review rows → 98,673 orders (551 surplus rows dropped from the review stage only) |
| 4 | NULL category → `unknown`; 2 untranslated categories translated manually | 610 + 13 products relabelled |
| 5 | Out-of-order stage timestamps → that stage NULL (order kept) | see §4 |
| 6 | `canceled` orders with a delivery date stay canceled | 6 orders excluded from delivery KPIs |
| 7 | Geolocation table not used (many-to-many on zip prefix, duplicates, coordinates outside Brazil) | n/a; state from `customers` is enough |
| 8 | State → macro-region mapping added (IBGE regions) | 27/27 customer states and 23/23 seller states mapped |

## 6. Small-sample handling
* Every rate is reported with its denominator.
* States with fewer than 300 delivered orders are flagged. Category rankings require ≥ 500 delivered orders. Seller rankings require ≥ 100 delivered orders.
* Seller and category "consistency" means the group's late rate exceeded the marketplace rate in at least 60% of quarters where it had ≥ 10 orders, with a minimum of 3 such quarters.
* The notebook's funnel plot shows that a naive top-10 seller list by late rate is made up entirely of sellers with fewer than 10 orders.

## 7. Interpretation rules and limitations
* **Association, not causation.** Late orders differ from on-time orders in region, category, seller and season. The review gap is shown within each region and under several exclusions, but no causal design is possible here.
* **Survey timing.** 74.5% of reviews on late orders were created *before* the order was delivered, so the survey appears to be sent around the estimated date. The −2.0-point gap falls to −0.77 when only post-delivery reviews are compared (n = 1,630 late orders).
* **Right-censoring.** Orders still in transit at the data cut-off (1,107 `shipped`) are excluded. They are probably late more often than average, so the last few months may understate lateness.
* **No carrier identity.** Carrier-stage delays can be located by lane (seller state → customer state) but can't be attributed to a specific logistics provider.
* **Seller attribution.** Delivery outcomes are order-level. In the 1.3% of multi-seller orders, every seller gets the same outcome.
* **No cost or profit data.** Order value is gross merchandise value (items + freight) in BRL.

## 8. SQLite migration and reconciliation record

The analysis was first built on DuckDB, then moved to SQLite. Before migrating, the validated DuckDB outputs were frozen: `reports/baseline/headline_metrics_duckdb.json` holds 34 headline metrics. On every build, `scripts/build_database.py` recomputes them in SQLite (`sql/05_headline_metrics.sql`) and writes [`reports/headline_reconciliation.md`](../reports/headline_reconciliation.md). It stops if a metric differs and the difference has no documented explanation.

| Check | Result |
|---|---|
| All `@check` validations (row counts, types, keys, FK, join cardinality, BRL totals) | pass |
| 34 headline metrics vs DuckDB baseline | 33 identical; 1 explained (lane definition, below) |
| Notebook text outputs vs the DuckDB-era run | identical (only a column header was renamed) |
| Full result tables `reports/sql_results/*.md` vs baseline | same values, with the differences listed below |

Differences found and how they were handled:
1. **Payment p99 (R$ 1,039.91 → 1,039.92) and the 7–10-instalment median payment (R$ 205.83 → 205.84).** The exact values are 1,039.9165 and 205.835. DuckDB had cut these percentiles to two decimals on its `DECIMAL(12,2)` columns instead of rounding; SQLite computes on REAL and rounds. The SQLite values are the correct ones.
2. **Tie order in rankings.** Rows with equal *displayed* values (for example two categories at 8.05%, or sellers at 14 excess late orders) were in arbitrary order. All rankings now sort on the unrounded value with an ID tie-breaker. In Q4a this changed the 20th seller listed: fa1c13f… has the higher unrounded Wilson bound (7.0785% vs 7.0774%).
3. **Shipping-lane grain (corrected during the Power BI reconciliation).** Q9b had counted (order, seller) pairs, so an order with two São Paulo sellers counted twice in SP → RJ. Lanes now use one row per (order, lane). SP → RJ: 8,274 → 8,188 delivered orders and 14.0% → 14.1% late; excess late orders stay ≈ 597. Seller-, category- and state-level results are unaffected.
4. **Cosmetic.** Q1 dates now print without a time, and table names lost the `analytics.`/`raw.` schema prefixes. Q3e gained a column, and `02` gained a stored-type check.

No conclusion changed.
