# Methodology

This page records the definitions, cleaning decisions and exclusions used in the analysis, and how each one affects the row counts. Every number here is produced by the SQL files, and the query results are saved in [reports/sql_results](../reports/sql_results/).

## 1. Pipeline

```
data/raw/*.csv                       original files, never modified
  sql/01_create_schema.sql           typed staging tables (raw_*)
  sql/02_load_and_validate.sql       load the CSVs, add key indexes, run data checks
raw_* tables                         exact copies of the 9 CSVs, in data/processed/olist.db
  sql/03_transform.sql               dimensions, fact tables, bridge tables, post-join checks
fct_* and dim_* tables               the star schema used for analysis
  sql/04_business_analysis.sql       business questions Q1 to Q9
  sql/05_headline_metrics.sql        key numbers used to cross-check the notebook and Power BI
  notebooks/01_delivery_and_reviews  independent pandas check and exploration
data/processed/*.csv                 exported tables loaded by the Power BI report
```

`scripts/build_database.py` uses only Python's standard library (sqlite3, csv and json). It recreates `data/processed/olist.db`, runs the five SQL files in order (about 3 to 4 minutes), and stops if any check fails. The checks cover raw row counts, stored data types and timestamp formats, unique keys, links between tables, row counts kept through joins, money totals kept after aggregation, and the state-to-region mapping. It then compares the key numbers with the earlier validated results (section 8) and exports the analysis tables to CSV for Power BI.

### Why SQLite, and what that changes

SQLite runs inside Python with no server, password or extra driver, so anyone can rebuild the database with one command. It has a few differences from larger databases that shaped the SQL:

- There are no schemas, so the two layers are separated by name: `raw_*` for the staging tables, and `fct_*`, `dim_*`, `stg_*` and the bridge tables for the analysis layer.
- There is no bulk CSV load command. The `-- @load:` lines in `02_load_and_validate.sql` are carried out by the Python script, which reads each CSV and inserts it into its table. Empty cells become NULL, the file header must match the table's columns, and the byte-order mark at the start of the category translation file is removed.
- Column types are not enforced, so `02` checks that every value was stored with the expected type and that every timestamp has the exact `YYYY-MM-DD HH:MM:SS` format. Timestamps stored that way sort correctly as text and work with SQLite's date functions.
- Yes/no flags are stored as 1 or 0, with NULL meaning "not applicable". Time differences are calculated in whole seconds with `unixepoch()` and then divided into days or hours.
- There is no median function. Medians and other percentiles are calculated with window functions using linear interpolation, which is the same method used by pandas, PERCENTILE_CONT in other databases, and MEDIAN in Power BI.
- Rankings are sorted on the exact, unrounded value with an ID as a tie-breaker, so rows that look equal after rounding still appear in their true order.

## 2. Avoiding double counting

- The orders table has one row per order. Order items, payments and reviews can each have several rows per order.
- Joining orders directly to items gives 113,425 rows for 99,441 orders, so 13,984 orders would be counted more than once. The notebook shows this.
- To avoid that, items, payments and reviews are each summarised to one row per order before they are joined. The build confirms that `fct_orders` has exactly 99,441 rows and that the total item value (R$ 15,843,553.24) and total payments (R$ 16,008,872.12) don't change.
- Seller and category figures use bridge tables with one row per order and seller, and one row per order and category, because the delivery date only exists at order level. 1,278 orders (1.3%) have more than one seller and 786 (0.8%) have more than one category. These orders count once in each group, and every group gets the same delivery result for that order.
- Shipping routes (seller state to customer state) use one row per order and route, so an order shipped by two sellers from the same state counts once on that route. The Power BI `Lane` column works the same way.
- In Power BI, order measures count rows of `fct_orders`. Filters on items, categories and sellers reach it through a two-way relationship between orders and items, so an order is never counted twice.

## 3. Metric definitions

| Metric | Counted per | Numerator | Denominator or population | Notes |
|---|---|---|---|---|
| Delivered orders (delivery metrics) | order | | status is delivered and a delivery timestamp exists: 96,470 | 2,971 orders left out (section 4) |
| Late-delivery rate | order | delivery date later than the promised date | delivered orders | 6,534 / 96,470 = 6.77% |
| Late-delivery rate, timestamp version | order | delivery timestamp later than the promised timestamp | delivered orders | 7,826 / 96,470 = 8.11% |
| Time per step | order | difference between the two timestamps | delivered orders where both timestamps exist and are in order | medians, 75th and 90th percentiles reported, because averages are skewed |
| Average review score | order | sum of scores | delivered orders with a review | one review per order |
| Canceled or unavailable share | order | status canceled or unavailable | all orders | 1,234 / 99,441 = 1.24% |
| Order value (BRL) | order | item price plus shipping | delivered orders | total sales value, not profit and not Olist's revenue |
| Excess late orders | group | late orders minus (delivered orders x marketplace late rate) | groups above a minimum size | combines rate and volume to set priorities |
| Wilson lower bound | group | lower end of the 95% confidence interval of the late rate | groups above a minimum size | a cautious rate that penalises small samples |
| Late handover to carrier | order | carrier pickup after the latest item shipping deadline | delivered orders with a pickup date | a sign of seller-side delay |

### Why the late-delivery definition was adapted

The project brief defines late as the delivery timestamp being later than the estimated delivery timestamp. In the data, all 99,441 estimated delivery values are at exactly midnight, so the estimate is really a date. A timestamp comparison would count an order delivered at 3pm on the promised day as late, which affects 1,292 orders. The main metric therefore compares calendar dates. The timestamp version is kept as `is_late_timestamp_rule` and reported next to it (8.11% against 6.77%). The conclusions are the same under both.

## 4. What each metric leaves out

| Metric | Included | Excluded | Reason |
|---|---:|---:|---|
| Late rate and delivery times | 96,470 | 1,107 shipped, 625 canceled, 609 unavailable, 314 invoiced, 301 processing, 5 created, 2 approved, and 8 delivered orders with no delivery date | not delivered, or no delivery timestamp |
| Purchase to payment approval | 96,456 | 14 | approval timestamp missing |
| Approval to carrier pickup | 95,105 | 1,365 | approval missing (14), pickup missing (1), or pickup before approval (1,350) |
| Carrier pickup to delivery | 96,446 | 24 | pickup missing (1) or delivery before pickup (23) |
| All three steps valid | 95,082 | 1,388 | any of the above |
| Review comparisons | 95,824 | 646 | delivered orders with no review |
| Monthly trends | January 2017 to August 2018 | 329 orders before 2017, 20 orders from September 2018 | incomplete or very small months |

## 5. Cleaning decisions

| # | Decision | Effect |
|---|---|---|
| 1 | Raw files are loaded unchanged; all cleaning happens in the analysis tables | no rows changed in `raw_*` |
| 2 | Every order is kept in `fct_orders`, and flags decide which metrics it counts towards | 99,441 orders in, 99,441 out |
| 3 | One review per order, the most recently answered one | 99,224 review rows become 98,673 reviewed orders |
| 4 | Missing categories become `unknown`; 2 categories missing from the translation file were translated by hand | 610 and 13 products relabelled |
| 5 | A step with timestamps in the wrong order is left blank, but the order is kept | see section 4 |
| 6 | Canceled orders that have a delivery date stay canceled | 6 orders left out of delivery metrics |
| 7 | The geolocation file is not used (many rows per zip code, duplicates, some coordinates outside Brazil) | the customer's state is enough |
| 8 | States are mapped to Brazil's five official regions | all 27 customer states and 23 seller states mapped |

## 6. Small samples

- Every rate is shown with the number of orders behind it.
- States with fewer than 300 delivered orders are flagged. Category rankings need at least 500 delivered orders and seller rankings at least 100.
- A seller or category counts as "consistently" late if its late rate was above the marketplace rate in at least 60% of the quarters where it had 10 or more orders, with at least 3 such quarters.
- The notebook's funnel chart shows that a simple top-10 list of sellers by late rate is made up entirely of sellers with fewer than 10 orders.

## 7. How to read the results

- These are associations, not causes. Late orders differ from on-time orders in region, category, seller and season. The review gap was checked within each region and with several groups removed, but this data can't prove cause and effect.
- Survey timing matters. 74.5% of reviews on late orders were created before the order was delivered, so the survey seems to be sent around the promised date. The 2.0-star gap falls to 0.77 stars when only reviews written after delivery are compared (1,630 late orders).
- Orders still in transit when the data ends (1,107 marked as shipped) are left out. They are probably late more often than average, so the last few months may understate lateness.
- The data doesn't name the carrier, so transit delays can be traced to a route but not to a specific logistics company.
- Delivery results are recorded per order. In the 1.3% of orders with several sellers, every seller gets the same result.
- There is no cost or profit data. Order value is total sales value (items plus shipping) in BRL.

## 8. Moving from DuckDB to SQLite

The analysis was first built in DuckDB and then moved to SQLite. Before the move, the validated results were saved: `reports/baseline/headline_metrics_duckdb.json` holds 34 key numbers. Every SQLite build recalculates them (`sql/05_headline_metrics.sql`), writes the comparison to [reports/headline_reconciliation.md](../reports/headline_reconciliation.md), and stops if a number changes without a documented reason.

| Check | Result |
|---|---|
| All data checks (row counts, types, keys, links between tables, joins, money totals) | pass |
| 34 key numbers compared with the DuckDB results | 33 identical, 1 explained (route definition, below) |
| Notebook output compared with the DuckDB-era run | identical apart from one renamed column header |
| All result tables in `reports/sql_results` compared with the earlier ones | same values, apart from the points below |

Differences and how they were handled:

1. Two percentile values changed by one cent: the 99th percentile payment (R$ 1,039.91 to 1,039.92) and the median payment for 7 to 10 instalments (R$ 205.83 to 205.84). The exact values are 1,039.9165 and 205.835. DuckDB had cut them to two decimals instead of rounding, so the SQLite values are the correct ones.
2. Rows that looked equal after rounding, such as two categories at 8.05% or sellers with 14 excess late orders, used to appear in an arbitrary order. Rankings now sort on the exact value. In question Q4a this changed the 20th seller on the list, because seller fa1c13f has a slightly higher exact value (7.0785% against 7.0774%).
3. While checking Power BI against SQL, I found that the route analysis (Q9b) counted an order twice when it had two sellers from the same state. Routes now count each order once. São Paulo to Rio de Janeiro went from 8,274 to 8,188 delivered orders and from 14.0% to 14.1% late. The excess stays at about 597 late orders, and the seller, category and state results are not affected.
4. Cosmetic changes: dates in Q1 no longer show a time, table names no longer have a schema prefix, Q3e has an extra column, and step 02 has an extra data-type check.

None of the conclusions changed.
