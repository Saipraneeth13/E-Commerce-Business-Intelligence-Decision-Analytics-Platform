#!/usr/bin/env bash
# End-to-end run:  bash run_all.sh   (put the 9 Olist CSVs in data/raw/ first)
set -euo pipefail
cd "$(dirname "$0")/src"
python clean_data.py
python analysis.py
# Optional - needs a running PostgreSQL and `createdb olist_bi`:
# python load_postgres.py
# psql -d olist_bi -f ../sql/02_analysis_queries.sql
