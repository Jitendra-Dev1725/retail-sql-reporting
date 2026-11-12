# Retail SQL Reporting (Week 4: Dynamic Reporting and Data Visualization Using SQL)

SQL reporting project for a simulated virtual retail business (PostgreSQL 14+).

## Contents
| File | Description |
|---|---|
| `schema.sql` | Tables, supporting indexes, parameterised `sales_report()` function, `mv_daily_sales` materialized view, refresh procedure and refresh log |
| `reporting_queries.sql` | Eight analytical queries: best sellers, monthly trend with MoM growth, inventory turnover, seasonality, RFM segmentation, low-stock alerts, Pareto/ABC, market basket |
| `Week4_Dynamic_Reporting_SQL_Report.docx` | Full report: explanations, mock outputs, performance notes and visualization strategy |

## How to run
```bash
createdb retail
psql -d retail -f schema.sql
psql -d retail -f reporting_queries.sql
```
Load sample data into the tables first; query outputs in the report are mock results.

## Techniques covered
Joins, aggregation, CTEs, subqueries, window functions (LAG, NTILE, running totals), conditional aggregation (FILTER), self-join, materialized views with `REFRESH ... CONCURRENTLY`, partial and covering indexes.

## Notes
- Revenue is net of discount and counts only `COMPLETED` orders.
- `pg_cron` is required only for the optional 15-minute refresh schedule.
