"""
Step 3 - Create the PostgreSQL schema and bulk-load the cleaned CSVs.

Works two ways (picked automatically):
  1. psycopg2 installed  -> COPY via psycopg2
  2. otherwise           -> COPY via the `psql` command-line client (\\copy)

Env vars (optional): PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD
Usage: createdb olist_bi && python src/load_postgres.py
"""
import os
import subprocess
import sys

from config import CLEAN_DIR, DB_DEFAULTS, ROOT

try:
    import psycopg2
except ImportError:
    psycopg2 = None

# Load order respects foreign keys
TABLES = ["category_translation", "products", "customers", "sellers", "orders",
          "order_items", "order_payments", "order_reviews", "geolocation_zip", "geolocation"]
SCHEMA = ROOT / "sql" / "01_schema.sql"


def conn_params() -> dict:
    return {
        "host": os.getenv("PGHOST", DB_DEFAULTS["host"]),
        "port": os.getenv("PGPORT", DB_DEFAULTS["port"]),
        "dbname": os.getenv("PGDATABASE", DB_DEFAULTS["dbname"]),
        "user": os.getenv("PGUSER", DB_DEFAULTS["user"]),
        "password": os.getenv("PGPASSWORD", DB_DEFAULTS["password"]),
    }


def load_with_psycopg2(p: dict):
    with psycopg2.connect(**p) as conn, conn.cursor() as cur:
        cur.execute(SCHEMA.read_text())
        for t in TABLES:
            with open(CLEAN_DIR / f"{t}.csv", encoding="utf-8") as f:
                cur.copy_expert(f"COPY {t} FROM STDIN WITH (FORMAT csv, HEADER true)", f)
            cur.execute(f"SELECT COUNT(*) FROM {t}")
            print(f"  {t:<22}{cur.fetchone()[0]:>10,} rows")


def load_with_psql(p: dict):
    env = {**os.environ, "PGHOST": p["host"], "PGPORT": p["port"], "PGDATABASE": p["dbname"],
           "PGUSER": p["user"], "PGPASSWORD": p["password"]}
    script = [f"\\i {SCHEMA}"]
    for t in TABLES:
        script.append(f"\\copy {t} FROM '{CLEAN_DIR / (t + '.csv')}' WITH (FORMAT csv, HEADER true)")
        script.append(f"SELECT '{t}' AS table_name, COUNT(*) AS rows FROM {t};")
    r = subprocess.run(["psql", "-v", "ON_ERROR_STOP=1", "-q", "-A", "-t", "-F", "  "],
                       input="\n".join(script), text=True, env=env, capture_output=True)
    out = [l for l in r.stdout.splitlines() if l.strip()]
    print("\n".join(f"  {l}" for l in out))
    if r.returncode != 0:
        sys.exit(f"psql failed:\n{r.stderr}")


def main():
    p = conn_params()
    if psycopg2:
        print("Loading with psycopg2")
        load_with_psycopg2(p)
    else:
        print("psycopg2 not installed - loading with the psql client")
        load_with_psql(p)
    print("Done. Run: psql -d olist_bi -f sql/02_analysis_queries.sql")


if __name__ == "__main__":
    main()
