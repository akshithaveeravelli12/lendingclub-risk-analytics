"""Step 1b: profile the source CSV *outside* Snowflake (pandas, chunked).

This is the "source" side of source-to-target reconciliation. Metrics are
written to data/source_profile.csv and to AUDIT.SOURCE_PROFILE, and a batch
id is saved to data/_batch_id.txt so 03_load_raw.py tags the load with it.

Usage:  python scripts/02_profile_source.py [path/to/file.csv.gz] [--no-upload]
"""
import os
import sys
from datetime import datetime
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv

load_dotenv()
DATA_DIR = Path(os.getenv("DATA_DIR", "data"))

AMOUNT_COLS = ["loan_amnt", "funded_amnt", "funded_amnt_inv", "out_prncp",
               "total_pymnt", "total_rec_prncp", "recoveries"]
KEY_COLS = ["id", "loan_amnt", "issue_d", "loan_status", "grade", "int_rate", "addr_state"]
CHUNK = 200_000


def find_source() -> Path:
    for name in ("accepted_2007_to_2018Q4.csv.gz", "accepted_2007_to_2018Q4.csv"):
        p = DATA_DIR / name
        if p.exists():
            return p
    raise SystemExit("Source file not found in data/. Run scripts/01_download.py first.")


def profile(path: Path) -> dict:
    m = {"ROW_COUNT": 0}
    sums = {c: 0.0 for c in AMOUNT_COLS}
    bad_num = {c: 0 for c in AMOUNT_COLS}
    nulls = {c: 0 for c in KEY_COLS}
    ids = []
    non_numeric_id = 0
    status_counts = pd.Series(dtype="int64")
    min_issue, max_issue = None, None

    reader = pd.read_csv(path, dtype=str, chunksize=CHUNK, keep_default_na=False,
                         na_values=[""], low_memory=False)
    for i, df in enumerate(reader, 1):
        m["ROW_COUNT"] += len(df)
        m["COLUMN_COUNT"] = df.shape[1]

        for c in KEY_COLS:
            nulls[c] += int(df[c].isna().sum())

        for c in AMOUNT_COLS:
            num = pd.to_numeric(df[c], errors="coerce")
            sums[c] += float(num.sum())
            bad_num[c] += int((num.isna() & df[c].notna()).sum())  # present but not a number

        id_num = pd.to_numeric(df["id"], errors="coerce")
        non_numeric_id += int(id_num.isna().sum())
        ids.append(df["id"].dropna())

        status_counts = status_counts.add(df["loan_status"].value_counts(), fill_value=0)

        issue = pd.to_datetime(df["issue_d"], format="%b-%Y", errors="coerce")
        if issue.notna().any():
            lo, hi = issue.min(), issue.max()
            min_issue = lo if min_issue is None or lo < min_issue else min_issue
            max_issue = hi if max_issue is None or hi > max_issue else max_issue

        print(f"  chunk {i}: {m['ROW_COUNT']:,} rows so far", flush=True)

    all_ids = pd.concat(ids, ignore_index=True)
    m["DISTINCT_ID"] = int(all_ids.nunique())
    m["DUPLICATE_ID_ROWS"] = int(all_ids.duplicated().sum())
    m["NON_NUMERIC_ID_ROWS"] = non_numeric_id  # summary/footer rows, blank ids
    for c in AMOUNT_COLS:
        m[f"SUM_{c.upper()}"] = round(sums[c], 2)
        m[f"NON_NUMERIC:{c}"] = bad_num[c]
    for c in KEY_COLS:
        m[f"NULL_COUNT:{c}"] = nulls[c]
    for status, n in status_counts.items():
        m[f"STATUS_COUNT:{status}"] = int(n)
    if min_issue is not None:
        m["MIN_ISSUE_YYYYMM"] = min_issue.year * 100 + min_issue.month
        m["MAX_ISSUE_YYYYMM"] = max_issue.year * 100 + max_issue.month
    return m


def upload(batch_id: str, source_file: str, metrics: dict):
    from sf_conn import get_conn
    rows = [(batch_id, source_file, k, v) for k, v in metrics.items()]
    with get_conn("AUDIT") as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM AUDIT.SOURCE_PROFILE WHERE BATCH_ID = %s", (batch_id,))
        cur.executemany(
            "INSERT INTO AUDIT.SOURCE_PROFILE (BATCH_ID, SOURCE_FILE, METRIC_NAME, METRIC_VALUE) "
            "VALUES (%s, %s, %s, %s)", rows)
    print(f"Wrote {len(rows)} metrics to AUDIT.SOURCE_PROFILE")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    path = Path(args[0]) if args else find_source()
    batch_id = "LC_" + datetime.now().strftime("%Y%m%d_%H%M%S")
    print(f"Profiling {path} (batch {batch_id})...")

    metrics = profile(path)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    pd.DataFrame(list(metrics.items()), columns=["metric_name", "metric_value"]) \
        .to_csv(DATA_DIR / "source_profile.csv", index=False)
    (DATA_DIR / "_batch_id.txt").write_text(batch_id)

    for k in ("ROW_COUNT", "DISTINCT_ID", "DUPLICATE_ID_ROWS", "NON_NUMERIC_ID_ROWS",
              "SUM_LOAN_AMNT", "SUM_FUNDED_AMNT", "MIN_ISSUE_YYYYMM", "MAX_ISSUE_YYYYMM"):
        if k in metrics:
            v = metrics[k]
            print(f"  {k:<22} {v:>20}" if "YYYYMM" in k else f"  {k:<22} {v:>20,}")

    if "--no-upload" not in sys.argv:
        upload(batch_id, path.name, metrics)


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).parent))
    main()
