# Loan Portfolio Risk & Delinquency Analytics

LendingClub accepted loans, 2007–2018Q4 → Snowflake (RAW → STAGING → MARTS) → Power BI.

## Step 1: Download + RAW layer

### 0. Prereqs
- Snowflake trial account (30 days of free credits is plenty; an X-Small warehouse loads this in minutes)
- Kaggle account → Settings → **Create New Token** → save `kaggle.json` to `~/.kaggle/` (Windows: `C:\Users\<you>\.kaggle\`)
- Python 3.10+

```bash
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env                                  # fill in your Snowflake details
```

### 1. Run in this order

| # | What | Where |
|---|------|-------|
| 1 | `python scripts/01_download.py` | terminal: pulls ~1.6 GB from Kaggle |
| 2 | `sql/00_setup.sql` | Snowflake worksheet: warehouse, DB, schemas, file format, stage, audit tables |
| 3 | `python scripts/02_profile_source.py` | terminal: profiles the CSV *before* load (source side of reconciliation) |
| 4 | `python scripts/03_load_raw.py` | terminal: generates DDL, PUTs file, COPYs into `RAW.LC_LOANS_RAW`, logs to `AUDIT` |
| 5 | `sql/01_raw_checks.sql` | Snowflake worksheet: sanity checks on the raw table |

### Design choices (worth saying in an interview)
- **RAW is all VARCHAR.** No type casting at load, so nothing gets silently dropped or coerced. Typing happens in STAGING, where bad values are counted, not lost.
- **Lineage columns** on every row: `_BATCH_ID`, `_SOURCE_FILE`, `_SOURCE_ROW_NUMBER`, `_LOADED_AT`.
- **Source profile captured independently** (pandas, outside Snowflake) and stored in `AUDIT.SOURCE_PROFILE`, so Step 2 reconciliation compares two independent counts, not Snowflake against itself.
- **COPY results logged** to `AUDIT.LOAD_LOG` (rows parsed, rows loaded, errors).

## Project layout
```
scripts/   Python: download, profile, load, shared Snowflake connection
sql/       Snowflake DDL and checks (staging/marts/recon added in later steps)
data/      local data (git-ignored)
```
