"""
Step 2 - Business analysis: where does the marketplace lose revenue and satisfaction?

Reads  : data/clean/*.csv
Writes : reports/kpi_summary.json
         reports/tables/*.csv         (tables that feed the Power BI dashboard)
         reports/figures/*.png

Metric definitions
  Revenue        = SUM(item price) on delivered orders (freight excluded)
  Late order     = delivered order whose customer delivery date > estimated date
  Repeat rate    = share of customers (customer_unique_id) with 2+ distinct orders
  Cancellation   = orders with status canceled / all orders

Usage  : python src/analysis.py
"""
import json

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd
import seaborn as sns

from config import CLEAN_DIR, FIG_DIR, REPORT_DIR

sns.set_theme(style="whitegrid", context="talk")
PALETTE = {"primary": "#2F5D8A", "alert": "#C8553D", "neutral": "#9AA5B1"}
TABLE_DIR = REPORT_DIR / "tables"


def load():
    rd = lambda n, **kw: pd.read_csv(CLEAN_DIR / f"{n}.csv", **kw)
    return dict(
        orders=rd("orders", parse_dates=["order_purchase_timestamp", "order_delivered_customer_date",
                                        "order_estimated_delivery_date"]),
        items=rd("order_items"), products=rd("products"), customers=rd("customers"),
        sellers=rd("sellers"), payments=rd("order_payments"),
        reviews=rd("order_reviews", low_memory=False),
    )


def build_order_master(t: dict) -> pd.DataFrame:
    """One row per order with customer, item, payment and review information."""
    items = t["items"].groupby("order_id").agg(
        items=("order_item_id", "count"), revenue=("price", "sum"), freight=("freight_value", "sum"))
    pay = t["payments"].groupby("order_id").agg(
        payment_value=("payment_value", "sum"), installments=("payment_installments", "max"),
        payment_type=("payment_type", lambda s: s.mode().iat[0]))
    rev = (t["reviews"].sort_values("review_answer_timestamp")
           .drop_duplicates("order_id", keep="last")[["order_id", "review_score"]])
    om = (t["orders"].merge(t["customers"], on="customer_id", how="left")
          .merge(items, on="order_id", how="left")
          .merge(pay, on="order_id", how="left")
          .merge(rev, on="order_id", how="left"))
    return om


def savefig(name):
    FIG_DIR.mkdir(parents=True, exist_ok=True)
    plt.tight_layout()
    plt.savefig(FIG_DIR / f"{name}.png", dpi=150)
    plt.close()


def main():
    TABLE_DIR.mkdir(parents=True, exist_ok=True)
    t = load()
    om = build_order_master(t)
    delivered = om[om["is_delivered"] & om["order_delivered_customer_date"].notna()].copy()
    kpi = {}

    # ---------------- 1. Headline KPIs (the 8 dashboard KPIs) ---------------- #
    deliv_all = om[om["is_delivered"]]
    kpi["total_revenue"] = round(float(deliv_all["revenue"].sum()), 2)
    kpi["total_orders"] = int(len(om))
    kpi["delivered_orders"] = int(len(deliv_all))
    kpi["avg_order_value"] = round(float(deliv_all["revenue"].mean()), 2)
    kpi["late_delivery_rate_pct"] = round(float(delivered["is_late"].astype(float).mean() * 100), 2)
    kpi["avg_review_score"] = round(float(om["review_score"].mean()), 2)
    kpi["cancellation_rate_pct"] = round(float((om["order_status"] == "canceled").mean() * 100), 2)
    kpi["avg_delivery_days"] = round(float(delivered["delivery_days"].mean()), 1)

    # ---------------- 2. Delivery performance vs satisfaction ---------------- #
    sat = (delivered.dropna(subset=["review_score"])
           .groupby("is_late")["review_score"].agg(["mean", "count"]).round(2))
    kpi["review_score_on_time"] = float(sat.loc[0, "mean"])
    kpi["review_score_late"] = float(sat.loc[1, "mean"])
    kpi["late_orders"] = int(delivered["is_late"].sum())

    # bucket delay days -> review score
    bins = [-999, -7, 0, 3, 7, 14, 999]
    labels = ["7+ days early", "0-7 days early", "1-3 days late", "4-7 days late", "8-14 days late", "15+ days late"]
    delivered["delay_bucket"] = pd.cut(delivered["delay_days"], bins=bins, labels=labels)
    by_delay = (delivered.groupby("delay_bucket", observed=True)
                .agg(orders=("order_id", "count"), avg_review=("review_score", "mean")).round(2).reset_index())
    by_delay.to_csv(TABLE_DIR / "review_by_delay_bucket.csv", index=False)

    fig, ax = plt.subplots(figsize=(10, 5.5))
    colors = [PALETTE["primary"] if "early" in l else PALETTE["alert"] for l in by_delay["delay_bucket"]]
    ax.bar(by_delay["delay_bucket"].astype(str), by_delay["avg_review"], color=colors)
    ax.set_ylim(0, 5); ax.set_ylabel("Average review score"); ax.set_xlabel("")
    ax.set_title("Review scores collapse as deliveries run late")
    plt.xticks(rotation=25, ha="right")
    for i, v in enumerate(by_delay["avg_review"]):
        ax.text(i, v + 0.07, f"{v:.2f}", ha="center", fontsize=12)
    savefig("01_review_by_delay")

    # late rate by customer state
    state_late = (delivered.groupby("customer_state")
                  .agg(orders=("order_id", "count"), late_rate=("is_late", lambda s: s.astype(float).mean() * 100),
                       avg_delivery_days=("delivery_days", "mean"), avg_review=("review_score", "mean"))
                  .round(2).sort_values("late_rate", ascending=False).reset_index())
    state_late.to_csv(TABLE_DIR / "late_rate_by_state.csv", index=False)
    kpi["worst_states_by_late_rate"] = state_late[state_late["orders"] >= 500].head(3)[["customer_state", "late_rate"]].to_dict("records")

    top = state_late[state_late["orders"] >= 500].head(10).iloc[::-1]
    fig, ax = plt.subplots(figsize=(9, 6))
    ax.barh(top["customer_state"], top["late_rate"], color=PALETTE["alert"])
    ax.axvline(kpi["late_delivery_rate_pct"], color="black", ls="--", lw=1)
    ax.text(kpi["late_delivery_rate_pct"] + 0.2, 0, "national avg", fontsize=11)
    ax.set_xlabel("% of delivered orders arriving late"); ax.set_title("States with the highest late-delivery rate")
    savefig("02_late_rate_by_state")

    # ---------------- 3. Revenue concentration by category ---------------- #
    it = t["items"].merge(t["products"][["product_id", "product_category_english"]], on="product_id")
    it = it.merge(om[["order_id", "is_delivered"]], on="order_id")
    cat = (it[it["is_delivered"]].groupby("product_category_english")
           .agg(revenue=("price", "sum"), items_sold=("order_item_id", "count"), avg_price=("price", "mean"))
           .sort_values("revenue", ascending=False).reset_index())
    cat["revenue_share_pct"] = (cat["revenue"] / cat["revenue"].sum() * 100).round(2)
    cat["cumulative_share_pct"] = cat["revenue_share_pct"].cumsum().round(2)
    cat.round(2).to_csv(TABLE_DIR / "revenue_by_category.csv", index=False)
    kpi["top5_categories"] = cat.head(5)["product_category_english"].tolist()
    kpi["top5_revenue_share_pct"] = round(float(cat.head(5)["revenue_share_pct"].sum()), 1)

    top10 = cat.head(10).iloc[::-1]
    fig, ax = plt.subplots(figsize=(10, 6))
    ax.barh(top10["product_category_english"], top10["revenue"] / 1e3,
            color=[PALETTE["primary"] if i >= 5 else PALETTE["neutral"] for i in range(10)])
    ax.set_xlabel("Revenue (BRL thousands)")
    ax.set_title(f"Top 5 categories = {kpi['top5_revenue_share_pct']}% of revenue")
    savefig("03_top_categories")

    # ---------------- 4. Monthly revenue trend ---------------- #
    monthly = (deliv_all.groupby("purchase_month")
               .agg(orders=("order_id", "count"), revenue=("revenue", "sum")).reset_index())
    monthly = monthly[(monthly["purchase_month"] >= "2017-01") & (monthly["purchase_month"] <= "2018-08")]
    monthly["mom_growth_pct"] = (monthly["revenue"].pct_change() * 100).round(1)
    monthly.round(2).to_csv(TABLE_DIR / "monthly_revenue.csv", index=False)
    fig, ax = plt.subplots(figsize=(11, 5))
    ax.plot(monthly["purchase_month"], monthly["revenue"] / 1e3, marker="o", color=PALETTE["primary"])
    ax.set_ylabel("Revenue (BRL thousands)"); ax.set_title("Monthly revenue (delivered orders)")
    plt.xticks(rotation=60, ha="right")
    savefig("04_monthly_revenue")

    # ---------------- 5. Retention ---------------- #
    cust = om.groupby("customer_unique_id")["order_id"].nunique()
    kpi["unique_customers"] = int(len(cust))
    kpi["repeat_customers"] = int((cust > 1).sum())
    repeat_rate = float((cust > 1).mean() * 100)
    kpi["repeat_rate_pct"] = round(repeat_rate, 1)
    target_rate = repeat_rate * 1.10                     # +10% relative lift (3.12% -> 3.43%)
    kpi["retention_target_repeat_rate_pct"] = round(target_rate, 2)
    kpi["extra_repeat_customers_at_target"] = int(round(kpi["unique_customers"] * (target_rate - repeat_rate) / 100))
    avg_cust_rev = float(deliv_all.groupby("customer_unique_id")["revenue"].sum().mean())
    kpi["avg_revenue_per_customer"] = round(avg_cust_rev, 2)

    # Does a bad first experience hurt re-purchase?
    first = (om.sort_values("order_purchase_timestamp").drop_duplicates("customer_unique_id")
             [["customer_unique_id", "review_score", "is_late"]])
    first["repeat"] = first["customer_unique_id"].map(cust) > 1
    first["first_review_band"] = pd.cut(first["review_score"], [0, 2, 3, 5], labels=["1-2 (poor)", "3 (neutral)", "4-5 (good)"])
    ret = (first.groupby("first_review_band", observed=True)["repeat"].agg(["mean", "count"])
           .assign(mean=lambda d: (d["mean"] * 100).round(2)).reset_index()
           .rename(columns={"mean": "repeat_rate_pct", "count": "customers"}))
    ret.to_csv(TABLE_DIR / "repeat_rate_by_first_review.csv", index=False)

    fig, ax = plt.subplots(figsize=(7.5, 5))
    ax.bar(["One-time", "Repeat"], [100 - kpi["repeat_rate_pct"], kpi["repeat_rate_pct"]],
           color=[PALETTE["neutral"], PALETTE["primary"]])
    ax.set_ylabel("% of customers"); ax.set_title("Only %.1f%% of customers ever reorder" % kpi["repeat_rate_pct"])
    for i, v in enumerate([100 - kpi["repeat_rate_pct"], kpi["repeat_rate_pct"]]):
        ax.text(i, v + 1.5, f"{v:.1f}%", ha="center")
    savefig("05_repeat_rate")

    # ---------------- 6. Cancellations & payments ---------------- #
    status = om["order_status"].value_counts().rename_axis("order_status").reset_index(name="orders")
    status["share_pct"] = (status["orders"] / status["orders"].sum() * 100).round(2)
    status.to_csv(TABLE_DIR / "order_status.csv", index=False)
    pay = (t["payments"].groupby("payment_type")
           .agg(payments=("order_id", "count"), value=("payment_value", "sum"),
                avg_installments=("payment_installments", "mean")).round(2).reset_index())
    pay.to_csv(TABLE_DIR / "payment_mix.csv", index=False)

    # ---------------- 7. Seller performance ---------------- #
    sel = (t["items"].merge(om[["order_id", "is_delivered", "is_late", "review_score"]], on="order_id")
           .query("is_delivered")
           .groupby("seller_id")
           .agg(revenue=("price", "sum"), orders=("order_id", "nunique"),
                late_rate=("is_late", lambda s: s.astype(float).mean() * 100), avg_review=("review_score", "mean"))
           .round(2).sort_values("revenue", ascending=False).reset_index())
    sel.to_csv(TABLE_DIR / "seller_scorecard.csv", index=False)
    sel_rev = sel["revenue"].cumsum() / sel["revenue"].sum()
    kpi["top_20pct_sellers_revenue_share_pct"] = round(float(sel_rev.iloc[int(len(sel) * 0.2) - 1] * 100), 1)

    # ---------------- Output ---------------- #
    with open(REPORT_DIR / "kpi_summary.json", "w") as f:
        json.dump(kpi, f, indent=2)
    print(json.dumps(kpi, indent=2))


if __name__ == "__main__":
    main()
