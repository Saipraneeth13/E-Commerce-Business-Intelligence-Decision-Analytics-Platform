# Power BI model and DAX measures

## 1. Data model (Import mode, PostgreSQL connector → database `olist_bi`)

| Power BI table | Source | Grain | Notes |
|---|---|---|---|
| `Orders` | `vw_order_master` | 1 row / order | Fact table: revenue, review score, delay, status |
| `OrderItems` | `order_items` | 1 row / item | Used for category and seller revenue |
| `Products` | `products` | 1 row / product | Has `product_category_english` |
| `Sellers` | `sellers` | 1 row / seller | |
| `Customers` | `customers` | 1 row / customer_id | Keep `customer_unique_id` for retention |
| `Calendar` | DAX (below) | 1 row / day | Mark as date table |

Relationships (all many-to-one, single direction):
`Orders[order_id] → OrderItems[order_id]` is **one-to-many** from Orders. `OrderItems[product_id] → Products[product_id]`,
`OrderItems[seller_id] → Sellers[seller_id]`, `Orders[order_purchase_date] → Calendar[Date]`.

## 2. Calendar table
```DAX
Calendar =
ADDCOLUMNS (
    CALENDAR ( DATE ( 2017, 1, 1 ), DATE ( 2018, 8, 31 ) ),
    "Year", YEAR ( [Date] ),
    "Month No", MONTH ( [Date] ),
    "Month", FORMAT ( [Date], "MMM YYYY" ),
    "YearMonth", FORMAT ( [Date], "YYYY-MM" )
)
```
Add a column in Power Query: `Orders[order_purchase_date] = DateTime.Date([order_purchase_timestamp])`.

## 3. The 8 KPIs
```DAX
1. Total Revenue =
CALCULATE ( SUM ( Orders[revenue] ), Orders[is_delivered] = TRUE () )

2. Total Orders =
DISTINCTCOUNT ( Orders[order_id] )

3. Average Order Value =
DIVIDE ( [Total Revenue], CALCULATE ( DISTINCTCOUNT ( Orders[order_id] ), Orders[is_delivered] = TRUE () ) )

4. Late Delivery Rate % =
DIVIDE (
    CALCULATE ( COUNTROWS ( Orders ), Orders[is_late] = 1 ),
    CALCULATE ( COUNTROWS ( Orders ), Orders[is_late] IN { 0, 1 } )
)

5. Avg Review Score =
AVERAGE ( Orders[review_score] )

6. Cancellation Rate % =
DIVIDE ( CALCULATE ( COUNTROWS ( Orders ), Orders[order_status] = "canceled" ), COUNTROWS ( Orders ) )

7. Repeat Customer Rate % =
VAR PerCustomer =
    ADDCOLUMNS ( VALUES ( Orders[customer_unique_id] ), "@n", CALCULATE ( DISTINCTCOUNT ( Orders[order_id] ) ) )
RETURN
    DIVIDE ( COUNTROWS ( FILTER ( PerCustomer, [@n] > 1 ) ), COUNTROWS ( PerCustomer ) )

8. Avg Delivery Days =
CALCULATE ( AVERAGE ( Orders[delivery_days] ), Orders[is_delivered] = TRUE () )
```

## 4. Supporting measures
```DAX
Avg Review - Late =
CALCULATE ( [Avg Review Score], Orders[is_late] = 1 )

Avg Review - On Time =
CALCULATE ( [Avg Review Score], Orders[is_late] = 0 )

Review Score Gap =
[Avg Review - On Time] - [Avg Review - Late]

Revenue MoM % =
VAR Prev = CALCULATE ( [Total Revenue], DATEADD ( 'Calendar'[Date], -1, MONTH ) )
RETURN DIVIDE ( [Total Revenue] - Prev, Prev )

Category Revenue Share % =
DIVIDE (
    CALCULATE ( SUM ( OrderItems[price] ), Orders[is_delivered] = TRUE () ),
    CALCULATE ( SUM ( OrderItems[price] ), Orders[is_delivered] = TRUE (), ALL ( Products ) )
)

Top 5 Category Share % =
VAR Top5 = TOPN ( 5, ALL ( Products[product_category_english] ), [Total Revenue] )
RETURN DIVIDE ( CALCULATE ( [Total Revenue], Top5 ), CALCULATE ( [Total Revenue], ALL ( Products ) ) )

Retention Target % (10% lift) =
[Repeat Customer Rate %] * 1.10
```
`Total Revenue` here is order-level revenue; when slicing by category use the item-level
`Category Revenue` measure: `CALCULATE ( SUM ( OrderItems[price] ), Orders[is_delivered] = TRUE () )`.

## 5. Suggested report pages
1. **Executive overview** – 8 KPI cards, monthly revenue line, revenue by state map.
2. **Sales & categories** – category Pareto (bar + cumulative line), top sellers table.
3. **Delivery & satisfaction** – late rate by state, review score by delay bucket, on-time vs late review cards.
4. **Retention & cancellations** – repeat rate card, orders-per-customer histogram, cancellation trend.

Import the CSVs in `reports/tables/` if you prefer not to connect to PostgreSQL.
