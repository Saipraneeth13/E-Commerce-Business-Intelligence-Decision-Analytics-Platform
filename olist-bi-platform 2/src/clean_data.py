"""
Step 1 - Clean and validate the 9 Olist relational tables.

Reads  : data/raw/*.csv
Writes : data/clean/*.csv            (cleaned tables, Postgres-ready)
         reports/cleaning_report.json (before/after counts, validation results)

Usage  : python src/clean_data.py
"""
import json

import pandas as pd

from config import (CLEAN_DIR, EXTRA_CATEGORY_TRANSLATIONS, ORDER_DATE_COLS,
                    RAW_DIR, RAW_FILES, REPORT_DIR)


def load_raw() -> dict[str, pd.DataFrame]:
    return {name: pd.read_csv(RAW_DIR / f) for name, f in RAW_FILES.items()}


# --------------------------------------------------------------------------- #
# Table-level cleaning
# --------------------------------------------------------------------------- #
def clean_geolocation(df: pd.DataFrame, log: dict) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Drop exact duplicate rows; also build one-row-per-zip centroid table."""
    before = len(df)
    df = df.drop_duplicates().copy()
    log["geolocation"] = {"rows_before": before, "rows_after": len(df),
                          "duplicates_removed": before - len(df)}
    # Standardise city text (accents/case vary a lot in this table)
    df["geolocation_city"] = df["geolocation_city"].str.strip().str.lower()
    zip_centroids = (df.groupby("geolocation_zip_code_prefix", as_index=False)
                       .agg(lat=("geolocation_lat", "mean"),
                            lng=("geolocation_lng", "mean"),
                            city=("geolocation_city", lambda s: s.mode().iat[0]),
                            state=("geolocation_state", lambda s: s.mode().iat[0])))
    zip_centroids = zip_centroids.rename(columns={"geolocation_zip_code_prefix": "zip_code_prefix"})
    return df, zip_centroids


def clean_products(products: pd.DataFrame, translation: pd.DataFrame, log: dict) -> pd.DataFrame:
    p = products.rename(columns={"product_name_lenght": "product_name_length",
                                 "product_description_lenght": "product_description_length"}).copy()
    missing_cat = int(p["product_category_name"].isna().sum())
    p["product_category_name"] = p["product_category_name"].fillna("unknown")

    tr = dict(zip(translation["product_category_name"], translation["product_category_name_english"]))
    tr.update(EXTRA_CATEGORY_TRANSLATIONS)
    tr["unknown"] = "unknown"
    p["product_category_english"] = p["product_category_name"].map(tr)

    # Numeric attributes: impute with the category median (fall back to global median)
    num_cols = ["product_name_length", "product_description_length", "product_photos_qty",
                "product_weight_g", "product_length_cm", "product_height_cm", "product_width_cm"]
    imputed = {}
    for c in num_cols:
        n = int(p[c].isna().sum())
        p[c] = p[c].fillna(p.groupby("product_category_name")[c].transform("median"))
        p[c] = p[c].fillna(p[c].median())
        imputed[c] = n
    log["products"] = {"rows": len(p), "missing_category_fixed": missing_cat,
                       "untranslated_categories_after": int(p["product_category_english"].isna().sum()),
                       "numeric_values_imputed": imputed}
    return p


def clean_orders(orders: pd.DataFrame, log: dict) -> pd.DataFrame:
    o = orders.copy()
    for c in ORDER_DATE_COLS:
        o[c] = pd.to_datetime(o[c], errors="coerce")
    # Derived delivery metrics (used throughout the analysis)
    o["is_delivered"] = o["order_status"].eq("delivered")
    o["delivery_days"] = (o["order_delivered_customer_date"] - o["order_purchase_timestamp"]).dt.total_seconds() / 86400
    o["estimated_days"] = (o["order_estimated_delivery_date"] - o["order_purchase_timestamp"]).dt.total_seconds() / 86400
    o["delay_days"] = (o["order_delivered_customer_date"] - o["order_estimated_delivery_date"]).dt.total_seconds() / 86400
    o["is_late"] = (o["is_delivered"] & (o["delay_days"] > 0)).astype("Int8")
    o.loc[~o["is_delivered"] | o["order_delivered_customer_date"].isna(), "is_late"] = pd.NA
    o["purchase_month"] = o["order_purchase_timestamp"].dt.to_period("M").astype(str)

    anomalies = {
        "delivered_without_delivery_date": int((o["is_delivered"] & o["order_delivered_customer_date"].isna()).sum()),
        "delivered_before_purchase": int((o["delivery_days"] < 0).sum()),
        "status_counts": o["order_status"].value_counts().to_dict(),
    }
    log["orders"] = {"rows": len(o), **anomalies}
    return o


def clean_reviews(reviews: pd.DataFrame, log: dict) -> pd.DataFrame:
    r = reviews.copy()
    for c in ["review_creation_date", "review_answer_timestamp"]:
        r[c] = pd.to_datetime(r[c], errors="coerce")
    before = len(r)
    r = r.drop_duplicates()
    dup_review_id = int(r["review_id"].duplicated().sum())
    # Keep the most recent review per (review_id, order_id) pair
    r = (r.sort_values("review_answer_timestamp")
           .drop_duplicates(subset=["review_id", "order_id"], keep="last"))
    r["has_comment"] = r["review_comment_message"].notna()
    log["order_reviews"] = {"rows_before": before, "rows_after": len(r),
                            "review_ids_reused_across_orders": dup_review_id,
                            "orders_with_multiple_reviews": int(r["order_id"].duplicated().sum())}
    return r


def clean_simple(df: pd.DataFrame, name: str, log: dict, text_cols=()) -> pd.DataFrame:
    before = len(df)
    df = df.drop_duplicates().copy()
    for c in text_cols:
        df[c] = df[c].str.strip().str.lower()
    log[name] = {"rows_before": before, "rows_after": len(df), "duplicates_removed": before - len(df)}
    return df


# --------------------------------------------------------------------------- #
# Validation
# --------------------------------------------------------------------------- #
def validate(t: dict[str, pd.DataFrame]) -> dict:
    checks = {}

    def add(name, ok, detail=""):
        checks[name] = {"passed": bool(ok), "detail": detail}

    # Primary-key uniqueness
    add("pk_orders", t["orders"]["order_id"].is_unique)
    add("pk_customers", t["customers"]["customer_id"].is_unique)
    add("pk_products", t["products"]["product_id"].is_unique)
    add("pk_sellers", t["sellers"]["seller_id"].is_unique)
    add("pk_order_items", not t["order_items"].duplicated(["order_id", "order_item_id"]).any())
    add("pk_order_payments", not t["order_payments"].duplicated(["order_id", "payment_sequential"]).any())
    add("pk_order_reviews", not t["order_reviews"].duplicated(["review_id", "order_id"]).any())

    # Foreign-key integrity
    def fk(child, col, parent, pcol=None):
        pcol = pcol or col
        orphans = int((~t[child][col].isin(t[parent][pcol])).sum())
        add(f"fk_{child}.{col}->{parent}", orphans == 0, f"{orphans} orphan rows")

    fk("orders", "customer_id", "customers")
    fk("order_items", "order_id", "orders")
    fk("order_items", "product_id", "products")
    fk("order_items", "seller_id", "sellers")
    fk("order_payments", "order_id", "orders")
    fk("order_reviews", "order_id", "orders")

    # Domain / sanity checks
    add("review_score_1_to_5", t["order_reviews"]["review_score"].between(1, 5).all())
    add("price_positive", (t["order_items"]["price"] > 0).all())
    add("freight_non_negative", (t["order_items"]["freight_value"] >= 0).all())
    add("payment_value_non_negative", (t["order_payments"]["payment_value"] >= 0).all())
    add("orders_have_items", t["orders"]["order_id"].isin(t["order_items"]["order_id"]).mean() > 0.99,
        f"{t['orders']['order_id'].isin(t['order_items']['order_id']).mean():.2%} orders have items")
    add("no_null_product_category", t["products"]["product_category_name"].notna().all())
    return checks


def main():
    CLEAN_DIR.mkdir(parents=True, exist_ok=True)
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    raw = load_raw()
    log: dict = {}

    geo, zip_centroids = clean_geolocation(raw["geolocation"], log)
    tables = {
        "geolocation": geo,
        "geolocation_zip": zip_centroids,
        "products": clean_products(raw["products"], raw["category_translation"], log),
        "orders": clean_orders(raw["orders"], log),
        "order_reviews": clean_reviews(raw["order_reviews"], log),
        "customers": clean_simple(raw["customers"], "customers", log, ["customer_city"]),
        "sellers": clean_simple(raw["sellers"], "sellers", log, ["seller_city"]),
        "order_items": clean_simple(raw["order_items"], "order_items", log),
        "order_payments": clean_simple(raw["order_payments"], "order_payments", log),
        "category_translation": raw["category_translation"],
    }
    tables["order_items"]["shipping_limit_date"] = pd.to_datetime(tables["order_items"]["shipping_limit_date"])

    checks = validate(tables)
    total_dups = sum(v.get("duplicates_removed", 0) for v in log.values())
    log["summary"] = {
        "tables_cleaned": 9,
        "total_duplicate_rows_removed": total_dups,
        "missing_categories_fixed": log["products"]["missing_category_fixed"],
        "validation_checks_passed": sum(c["passed"] for c in checks.values()),
        "validation_checks_total": len(checks),
    }
    log["validation"] = checks

    for name, df in tables.items():
        df.to_csv(CLEAN_DIR / f"{name}.csv", index=False)
        print(f"  wrote data/clean/{name}.csv  {df.shape}")
    with open(REPORT_DIR / "cleaning_report.json", "w") as f:
        json.dump(log, f, indent=2, default=str)

    print("\nCleaning summary:", json.dumps(log["summary"], indent=2))
    failed = [k for k, v in checks.items() if not v["passed"]]
    if failed:
        print("Validation checks FAILED:", failed)


if __name__ == "__main__":
    main()
