# E-Commerce Business Intelligence & Decision Analytics Platform

**Stack:** Python · Pandas · SQL · PostgreSQL · Power BI · DAX
**Goal:** find where an online marketplace (Olist, Brazil) loses revenue and customer satisfaction across **sales, delivery and retention**.

Data: [Olist Brazilian E-Commerce dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) — 9 relational tables, 99,441 orders, Sep 2016 – Oct 2018.

---

## Key findings

| # | Finding | Number |
|---|---------|--------|
| 1 | Duplicate rows removed (all in the geolocation table) | **261,831** |
| 2 | Products with a missing category fixed (labelled `unknown`, translated) | **610** |
| 3 | Delivered orders that arrived after the estimated date | **8.1%** (7,826 of 96,470) |
| 4 | Review score, late vs on-time orders | **2.57 vs 4.29** (54% of late orders get 1-2 stars vs 9% on time) |
| 5 | Revenue share of the top 5 categories (health_beauty, watches_gifts, bed_bath_table, sports_leisure, computers_accessories) | **39.8%** |
| 6 | Customers who ever placed a second order | **3.1%** (2,997 of 96,096) |
| 7 | Cross-state shipments vs same-state: avg delivery days / late rate | 15.1 d / 9.3% vs 7.9 d / 6.1% |
| 8 | Worst late-delivery states (n ≥ 500 orders) | MA 19.7%, CE 15.3%, BA 14.0% vs 8.1% national |
| 9 | Seller concentration: top decile of sellers | 67% of revenue |

Headline KPIs: revenue **R$13.22M** (delivered, item price only) · AOV **R$137.04** · avg review **4.09** · avg delivery **12.6 days** · cancellation rate **0.63%**.

### What the numbers say
- **Delivery is the satisfaction lever.** Review score falls from 4.2 (on time) to 3.8 (1-3 days late), 2.3 (4-7 days late) and ~1.7 (8+ days late). Fixing late deliveries in the Northeast states and for cross-state shipments is the highest-impact operational fix.
- **Revenue is concentrated.** Five categories drive ~40% of revenue and 10% of sellers drive two-thirds — inventory, ad spend and seller-quality programmes should be focused there.
- **Retention is the biggest untapped pool.** Only 3.1% of customers reorder. A **10% relative lift** (3.12% → 3.43%) means about **300 extra repeat customers** on the current base.
- **Caveat worth knowing:** a bad first review does *not* predict lower repurchase in this data (repeat rate is ~3.1% for poor, neutral and good first reviews — see `Q26`). Retention campaigns should therefore be built around re-engagement (cross-sell, vouchers, post-delivery email) rather than only service recovery.

---

## Project structure

```
olist-bi-platform/
├── data/raw/                  # put the 9 Olist CSVs here (git-ignored)
├── data/clean/                # cleaned tables written by clean_data.py (git-ignored)
├── src/
│   ├── config.py              # paths, constants, DB defaults
│   ├── clean_data.py          # 1. clean + validate 9 tables
│   ├── analysis.py            # 2. KPIs, tables for Power BI, charts
│   └── load_postgres.py       # 3. build schema + bulk load into PostgreSQL
├── sql/
│   ├── 01_schema.sql          # tables, PK/FK, indexes, vw_order_master view
│   └── 02_analysis_queries.sql# 29 queries (joins, CTEs, window functions)
├── powerbi/dax_measures.md    # data model, 8 KPI measures, report layout
├── reports/
│   ├── cleaning_report.json   # before/after counts + 19 validation checks
│   ├── kpi_summary.json       # all headline numbers above
│   ├── tables/*.csv           # aggregated tables (importable into Power BI)
│   ├── figures/*.png          # charts
│   └── sql_query_results_sample.txt  # output of all 29 queries
├── run_all.sh
└── requirements.txt
```

## How to run

```bash
pip install -r requirements.txt
# copy the 9 CSVs into data/raw/
bash run_all.sh                 # clean -> analysis (about 30 seconds)

# PostgreSQL (optional but recommended)
createdb olist_bi
export PGUSER=postgres PGPASSWORD=postgres
python src/load_postgres.py     # schema + load (uses psycopg2 if installed, else the psql client)
psql -d olist_bi -f sql/02_analysis_queries.sql
```

Then in Power BI Desktop: **Get Data → PostgreSQL** (`olist_bi`), load `vw_order_master`, `order_items`, `products`, `sellers`, `customers`, and paste the measures from `powerbi/dax_measures.md`. (Or import the CSVs in `reports/tables/`.)

---

## Pipeline details

### 1. Cleaning and validation (`clean_data.py`)
| Table | Action |
|---|---|
| geolocation | Exact duplicates dropped (1,000,163 → 738,332); city text standardised; one-row-per-zip centroid table added |
| products | 610 null categories → `unknown`; Portuguese → English names, 2 missing translations added manually; 610 + 2 null numeric fields imputed by category median; `lenght` typos renamed |
| orders | Timestamps parsed; derived `delivery_days`, `estimated_days`, `delay_days`, `is_late`, `purchase_month` |
| order_reviews | Parsed dates; one review kept per (review_id, order_id); `has_comment` flag |
| customers / sellers | Text standardised; duplicate check |
| order_items / payments | Types fixed; duplicate check |

**19 automated validation checks** all pass: primary-key uniqueness on every table, foreign-key integrity (0 orphan rows across 6 relationships), score range 1-5, positive prices, non-negative freight and payments.

### 2. Metric definitions
- **Revenue** = `SUM(item price)` on delivered orders (freight excluded).
- **Late order** = delivered order with `delivered_customer_date > estimated_delivery_date`; rate computed over delivered orders that have a delivery date.
- **Repeat customer** = `customer_unique_id` with 2+ distinct orders (`customer_id` is per-order in Olist, so it cannot be used for retention).
- **Cancellation rate** = orders with status `canceled` ÷ all orders.

### 3. SQL (`sql/02_analysis_queries.sql`)
29 PostgreSQL queries, grouped as Sales (Q01-Q10), Delivery (Q11-Q18), Satisfaction (Q19-Q22), Retention (Q23-Q27) and Cancellations (Q28-Q29). Techniques: multi-table joins, CTEs, `LAG`, `RANK`/`DENSE_RANK`, `NTILE`, running totals, moving-average window frames, `FILTER`, `DISTINCT ON`, `PERCENTILE_CONT`, and monthly cohort retention. The SQL results match the Python results exactly (e.g. top-5 share 39.8%, late rate 8.11%, 4.29 vs 2.57).

### 4. Power BI (`powerbi/dax_measures.md`)
Star-style model on `vw_order_master`, a Calendar table, and 8 KPI measures: Total Revenue, Total Orders, AOV, Late Delivery Rate %, Avg Review Score, Cancellation Rate %, Repeat Customer Rate %, Avg Delivery Days — plus supporting measures (MoM growth, top-5 share, review gap, 10%-lift retention target) and a 4-page report layout.

---

## Recommendations
1. **Delivery:** renegotiate carrier SLAs and widen estimated-delivery buffers in MA, CE and BA; prefer same-state sellers where stock allows.
2. **Inventory & marketing:** prioritise the top-5 categories; track seller scorecards (Q10) and coach low-review, high-late sellers.
3. **Retention:** launch post-delivery re-engagement (voucher or cross-sell) aimed at lifting the repeat rate from 3.1% to ~3.4% and measure it with the cohort query (Q27).
