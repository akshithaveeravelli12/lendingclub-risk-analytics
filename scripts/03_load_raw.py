"""Step 1c: load the source file into RAW.LC_LOANS_RAW.

1. Reads the CSV header and generates an all-VARCHAR table + lineage columns
2. PUTs the file to @RAW.STG_LC (gzip kept as-is)
3. COPY INTO with ON_ERROR=CONTINUE, tagging every row with batch/file/row number
4. Logs the COPY result to AUDIT.LOAD_LOG

Run 02_profile_source.py first (it creates the batch id).
"""
import csv
import gzip
import os
import re
import sys
from pathlib import Path

from dotenv import load_dotenv

sys.path.insert(0, str(Path(__file__).parent))
from sf_conn import get_conn  # noqa: E402

load_dotenv()
DATA_DIR = Path(os.getenv("DATA_DIR", "data"))
TABLE = "RAW.LC_LOANS_RAW"
STAGE_PATH = "@RAW.STG_LC/accepted/"


def find_source() -> Path:
    for name in ("accepted_2007_to_2018Q4.csv.gz", "accepted_2007_to_2018Q4.csv"):
        p = DATA_DIR / name
        if p.exists():
            return p
    raise SystemExit("Source file not found in data/. Run scripts/01_download.py first.")


def read_header(path: Path) -> list[str]:
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", encoding="utf-8", newline="") as f:
        return next(csv.reader(f))


def clean_name(col: str) -> str:
    name = re.sub(r"[^0-9a-zA-Z_]", "_", col.strip()).upper()
    return f"C_{name}" if name[0].isdigit() else name


def main():
    path = find_source().resolve()
    batch_file = DATA_DIR / "_batch_id.txt"
    if not batch_file.exists():
        raise SystemExit("No batch id. Run scripts/02_profile_source.py first.")
    batch_id = batch_file.read_text().strip()

    cols = [clean_name(c) for c in read_header(path)]
    if len(set(cols)) != len(cols):
        raise SystemExit("Duplicate column names after cleaning; inspect the header.")
    print(f"{len(cols)} source columns; batch {batch_id}")

    col_ddl = ",\n    ".join(f"{c} VARCHAR" for c in cols)
    create_sql = f"""
CREATE OR REPLACE TABLE {TABLE} (
    {col_ddl},
    _BATCH_ID          VARCHAR,
    _SOURCE_FILE       VARCHAR,
    _SOURCE_ROW_NUMBER NUMBER,
    _LOADED_AT         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'LendingClub accepted loans 2007-2018Q4, landed as-is (all VARCHAR)'"""

    gz = path.suffix == ".gz"
    put_sql = (f"PUT 'file://{path.as_posix()}' {STAGE_PATH} OVERWRITE=TRUE PARALLEL=8 "
               + ("AUTO_COMPRESS=FALSE SOURCE_COMPRESSION=GZIP" if gz else "AUTO_COMPRESS=TRUE"))
    staged_name = path.name if gz else path.name + ".gz"

    select_list = ", ".join(f"${i}" for i in range(1, len(cols) + 1))
    copy_sql = f"""
COPY INTO {TABLE} ({", ".join(cols)}, _BATCH_ID, _SOURCE_FILE, _SOURCE_ROW_NUMBER)
FROM (
    SELECT {select_list}, '{batch_id}', METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
    FROM {STAGE_PATH}{staged_name}
)
FILE_FORMAT = (FORMAT_NAME = 'RAW.FF_LC_CSV')
ON_ERROR = CONTINUE
FORCE = TRUE"""

    # Saved for the repo / for reviewing in a worksheet
    Path("sql/generated").mkdir(parents=True, exist_ok=True)
    Path("sql/generated/raw_lc_loans_ddl.sql").write_text(create_sql.strip() + ";\n\n" + copy_sql.strip() + ";\n")

    with get_conn("RAW") as conn:
        cur = conn.cursor()
        print("Creating table...")
        cur.execute(create_sql)
        print(f"Uploading {path.name} ({path.stat().st_size / 1e6:,.0f} MB) to stage...")
        cur.execute(put_sql)
        print("  ", cur.fetchone())
        print("COPY INTO...")
        cur.execute(copy_sql)
        names = [d[0].lower() for d in cur.description]
        for row in cur.fetchall():
            r = dict(zip(names, row))
            print(f"  {r.get('file')}: status={r.get('status')} parsed={r.get('rows_parsed')} "
                  f"loaded={r.get('rows_loaded')} errors={r.get('errors_seen')}")
            if r.get("first_error"):
                print(f"  first error: {r['first_error']}")
            cur.execute(
                "INSERT INTO AUDIT.LOAD_LOG (BATCH_ID, SOURCE_FILE, TARGET_TABLE, STATUS, ROWS_PARSED, "
                "ROWS_LOADED, ERRORS_SEEN, FIRST_ERROR) VALUES (%s,%s,%s,%s,%s,%s,%s,%s)",
                (batch_id, r.get("file"), TABLE, r.get("status"), r.get("rows_parsed"),
                 r.get("rows_loaded"), r.get("errors_seen"), r.get("first_error")))

        cur.execute(f"SELECT COUNT(*) FROM {TABLE} WHERE _BATCH_ID = %s", (batch_id,))
        print(f"Rows in {TABLE} for batch: {cur.fetchone()[0]:,}")


if __name__ == "__main__":
    main()
