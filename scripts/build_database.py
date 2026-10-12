"""Build the SQLite database, run validation and analysis SQL, export model tables.

Usage (from the project root or anywhere):
    python scripts/build_database.py

Uses only the Python standard library (sqlite3, csv, json). No database server.

Steps
  1. Verifies the nine raw Olist CSVs exist in data/raw/ (never modified).
  2. Recreates data/processed/olist.db and runs sql/01..05 in order.
     Directives inside the SQL files:
       -- @load: <table> <- <csv>   stream a raw CSV into a staging table
       -- @check: <title>           query must return `passed` = 1 on every row,
                                    otherwise the build stops
       -- @result: <title>          output saved to reports/sql_results/<file>.md
       -- @metrics: <title>         (metric, value) rows saved to
                                    reports/headline_metrics.json
  3. Reconciles the headline metrics with the validated pre-migration baseline
     (reports/baseline/headline_metrics_duckdb.json) and writes
     reports/headline_reconciliation.md. The build stops on an unexplained gap.
  4. Exports the analytics tables to data/processed/*.csv for Power BI.
"""
from __future__ import annotations

import csv
import json
import math
import re
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = ROOT / "data" / "raw"
PROCESSED_DIR = ROOT / "data" / "processed"
DB_PATH = PROCESSED_DIR / "olist.db"
SQL_DIR = ROOT / "sql"
RESULTS_DIR = ROOT / "reports" / "sql_results"
METRICS_PATH = ROOT / "reports" / "headline_metrics.json"
BASELINE_PATH = ROOT / "reports" / "baseline" / "headline_metrics_duckdb.json"
RECON_PATH = ROOT / "reports" / "headline_reconciliation.md"

RAW_FILES = [
    "olist_customers_dataset.csv",
    "olist_geolocation_dataset.csv",
    "olist_order_items_dataset.csv",
    "olist_order_payments_dataset.csv",
    "olist_order_reviews_dataset.csv",
    "olist_orders_dataset.csv",
    "olist_products_dataset.csv",
    "olist_sellers_dataset.csv",
    "product_category_name_translation.csv",
]

# Tables exported for the Power BI model (see powerbi/build_instructions.md).
EXPORT_TABLES = [
    "fct_orders",
    "fct_order_items",
    "fct_payments",
    "dim_customer",
    "dim_seller",
    "dim_product",
    "dim_state",
    "dim_date",
]

# Metrics whose value legitimately differs from the DuckDB baseline, with the
# reason. Anything not listed here must match within floating-point tolerance.
EXPLAINED_DIFFERENCES: dict[str, str] = {
    "sp_to_rj_lane_excess_late_orders":
        "definition corrected during the Power BI reconciliation: lanes now have one row per (order, lane) "
        "instead of (order, seller), so an order with two sellers in the same state counts once "
        "(SP -> RJ delivered orders 8,274 -> 8,188).",
}

# Directives must start the line, so the documentation lines in file headers
# ("--   -- @result: <title>") are not mistaken for real directives.
MARKER = re.compile(r"^--\s*@(result|check|metrics):\s*(.+)", re.M)
LOAD = re.compile(r"^--\s*@load:\s*(\w+)\s*<-\s*(\S+)", re.M)


def split_statements(sql: str) -> list[str]:
    """Split a SQL script on semicolons that end a line (no ';' inside strings here).

    Comment-only chunks are kept when they carry @load directives.
    """
    # A statement ends at ';' at end of line, optionally followed by a -- comment.
    parts = re.split(r";[ \t]*(?:--[^\n]*)?(?:\r?\n|$)", sql)
    return [p for p in parts if re.sub(r"--[^\n]*", "", p).strip() or LOAD.search(p)]


def has_sql(chunk: str) -> bool:
    return bool(re.sub(r"--[^\n]*", "", chunk).strip())


def load_csv(con: sqlite3.Connection, table: str, rel_path: str) -> None:
    """Stream a raw CSV into a staging table. Empty cells become NULL."""
    cols = [r[1] for r in con.execute(f"PRAGMA table_info({table})")]
    # utf-8-sig: product_category_name_translation.csv starts with a byte-order mark
    with open(ROOT / rel_path, encoding="utf-8-sig", newline="") as fh:
        reader = csv.reader(fh)
        header = next(reader)
        if header != cols:
            sys.exit(f"{rel_path}: header {header} does not match {table} columns {cols}")
        placeholders = ",".join("?" * len(cols))
        con.executemany(f"INSERT INTO {table} VALUES ({placeholders})",
                        ([v if v != "" else None for v in row] for row in reader))
    n = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
    print(f"  [load] {table:<40} {n:>9,} rows  <- {rel_path}")


def to_markdown(cols: list[str], rows: list[tuple], max_rows: int = 200) -> str:
    """Render query output as a GitHub markdown table."""
    # Columns holding measured quantities keep two decimals even when whole.
    decimal_hint = re.compile(r"pct|avg|score|median|mean|p75|p90|p99|rate|days|hours|ci95|gap|diff|ratio|value")

    def fmt(v, col):
        if v is None:
            return ""
        if col == "passed":
            return "True" if v else "False"
        if isinstance(v, float):
            if v.is_integer() and not decimal_hint.search(col):
                return f"{v:,.0f}"
            return f"{v:,.2f}"
        if isinstance(v, int):
            return f"{v:,}"
        return str(v).replace("|", "\\|")

    lines = ["| " + " | ".join(cols) + " |", "|" + "|".join("---" for _ in cols) + "|"]
    for row in rows[:max_rows]:
        lines.append("| " + " | ".join(fmt(v, c) for v, c in zip(row, cols)) + " |")
    if len(rows) > max_rows:
        lines.append(f"\n_{len(rows) - max_rows} more rows not shown._")
    return "\n".join(lines)


def run_sql_file(con: sqlite3.Connection, path: Path, metrics: dict) -> None:
    sections: list[str] = []
    failures: list[str] = []
    for stmt in split_statements(path.read_text(encoding="utf-8")):
        for table, rel in LOAD.findall(stmt):
            load_csv(con, table, rel)
        if not has_sql(stmt):
            continue
        marker = MARKER.search(stmt)
        if marker is None:
            con.execute(stmt)
            continue
        kind, title = marker.group(1), marker.group(2).strip()
        cur = con.execute(stmt)
        cols = [d[0] for d in cur.description]
        rows = cur.fetchall()
        if kind == "metrics":
            metrics.update({m: v for m, v in rows})
        status = ""
        if kind == "check":
            ok = all(r[cols.index("passed")] == 1 for r in rows)
            status = " — PASSED" if ok else " — **FAILED**"
            if not ok:
                failures.append(title)
        # Keep the comment block directly above the marker (stops at a blank line).
        block = re.split(r"\n\s*\n", stmt[: marker.start()].rstrip())[-1]
        notes = [l.strip()[2:].strip() for l in block.splitlines()
                 if l.strip().startswith("--") and not set(l.strip()[2:].strip()) <= set("-=")]
        note_md = ("\n" + "\n".join(f"> {n}" for n in notes) + "\n") if notes else ""
        sections.append(f"## {title}{status}\n{note_md}\nRows returned: {len(rows):,}\n\n{to_markdown(cols, rows)}\n")
        print(f"  [{kind}] {title}{status}")

    if sections:
        RESULTS_DIR.mkdir(parents=True, exist_ok=True)
        out = RESULTS_DIR / f"{path.stem}.md"
        header = (f"# Results: `sql/{path.name}`\n\n"
                  f"Generated by `scripts/build_database.py` (SQLite {sqlite3.sqlite_version}) on "
                  f"{datetime.now():%Y-%m-%d %H:%M}. Do not edit by hand.\n\n")
        out.write_text(header + "\n".join(sections), encoding="utf-8")
    if failures:
        sys.exit(f"Validation failed in {path.name}: {failures}")


def reconcile(metrics: dict) -> None:
    """Compare SQLite headline metrics with the validated DuckDB baseline."""
    METRICS_PATH.write_text(json.dumps({"engine": f"SQLite {sqlite3.sqlite_version}",
                                        "generated": f"{datetime.now():%Y-%m-%d %H:%M}",
                                        "metrics": metrics}, indent=2), encoding="utf-8")
    if not BASELINE_PATH.exists():
        print("  (no baseline file - reconciliation skipped)")
        return
    baseline = json.loads(BASELINE_PATH.read_text(encoding="utf-8"))["metrics"]
    lines = ["# Headline metric reconciliation: SQLite vs validated DuckDB baseline", "",
             f"Generated by `scripts/build_database.py` on {datetime.now():%Y-%m-%d %H:%M}. "
             "Baseline: `reports/baseline/headline_metrics_duckdb.json` (frozen before the SQLite migration). "
             "Tolerance: relative 1e-9 (floating-point noise only).", "",
             "| metric | DuckDB baseline | SQLite | status |", "|---|---:|---:|---|"]
    unexplained = []
    for name, base in baseline.items():
        new = metrics.get(name)
        same = new is not None and math.isclose(float(new), float(base), rel_tol=1e-9, abs_tol=1e-9)
        if same:
            status = "match"
        elif name in EXPLAINED_DIFFERENCES:
            status = "explained: " + EXPLAINED_DIFFERENCES[name]
        else:
            status = "**UNEXPLAINED DIFFERENCE**"
            unexplained.append(name)
        lines.append(f"| {name} | {base:,.6g} | {'' if new is None else f'{new:,.6g}'} | {status} |")
    RECON_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
    matched = sum(1 for n in baseline if n not in unexplained and n not in EXPLAINED_DIFFERENCES)
    print(f"  {matched}/{len(baseline)} headline metrics identical to the baseline; "
          f"{len(unexplained)} unexplained -> {RECON_PATH.relative_to(ROOT)}")
    if unexplained:
        sys.exit(f"Headline metrics differ from the validated baseline: {unexplained}")


def export_csv(con: sqlite3.Connection, table: str) -> None:
    out = PROCESSED_DIR / f"{table}.csv"
    cur = con.execute(f"SELECT * FROM {table}")
    with open(out, "w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh)
        w.writerow([d[0] for d in cur.description])
        n = 0
        for row in cur:
            w.writerow(["" if v is None else v for v in row])
            n += 1
    print(f"  {out.relative_to(ROOT)}  ({n:,} rows)")


def main() -> None:
    missing = [f for f in RAW_FILES if not (RAW_DIR / f).exists()]
    if missing:
        sys.exit("Missing raw files in data/raw/: " + ", ".join(missing)
                 + "\nRun `python scripts/download_data.py` or follow data/raw/README.md.")

    PROCESSED_DIR.mkdir(parents=True, exist_ok=True)
    if DB_PATH.exists():
        DB_PATH.unlink()
    con = sqlite3.connect(DB_PATH)
    con.execute("PRAGMA journal_mode = OFF")      # single-writer batch build
    con.execute("PRAGMA synchronous = OFF")
    print(f"SQLite {sqlite3.sqlite_version} -> {DB_PATH.relative_to(ROOT)}")

    metrics: dict = {}
    for sql_file in sorted(SQL_DIR.glob("0*.sql")):
        print(f"Running {sql_file.name}")
        run_sql_file(con, sql_file, metrics)
        con.commit()

    print("Reconciling headline metrics")
    reconcile(metrics)

    print("Exporting analytics tables for Power BI")
    for table in EXPORT_TABLES:
        export_csv(con, table)
    con.execute("VACUUM")
    con.close()
    print(f"Done. Database: {DB_PATH.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
