# Loan Portfolio Risk & Delinquency Analytics

LendingClub accepted loans, 2007–2018Q4 → Snowflake (RAW → STAGING → MARTS) → Power BI.

## Step 1: Download + RAW layer

### 0. Prereqs
- Snowflake trial account (30 days of free credits is plenty; an X-Small warehouse loads this in minutes)
- Kaggle account → Settings → API Tokens → **Create Legacy API Key** → save `kaggle.json` to `~/.kaggle/` (or, on Python 3.11+, a new API token in `~/.kaggle/access_token`)
- Python 3.9+
- Snowflake service user with key-pair auth: `sql/00b_service_user.sql` (no passwords in code or config)

```bash
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env                                  # fill in your Snowflake details
```

### 1. Run in this order

| # | What | Where |
|---|------|-------|
| 1 | `python scripts/01_download.py` | terminal: pulls ~1.6 GB from Kaggle |
| 2 | `sql/00_setup.sql`, then `sql/00b_service_user.sql` | Snowflake worksheet: warehouse, DB, schemas, file format, stage, audit tables; pipeline service user |
| 3 | `python scripts/02_profile_source.py` | terminal: profiles the CSV *before* load (source side of reconciliation) |
| 4 | `python scripts/03_load_raw.py` | terminal: generates DDL, PUTs file, COPYs into `RAW.LC_LOANS_RAW`, logs to `AUDIT` |
| 5 | `sql/01_raw_checks.sql` | Snowflake worksheet: source-vs-RAW reconciliation, status mix, yearly volume, data quality |

### Step 1 results
| Check | Result |
|---|---|
| Rows in source file / loaded to RAW | 2,260,701 / 2,260,701 (0 COPY errors) |
| Real loans (excl. 33 LendingClub summary rows) | 2,260,668 |
| Total loan amount | $34.02B (Jun 2007 – Dec 2018) |
| Source-vs-RAW reconciliation | 8/8 PASS; only variance $0.31 on $27.3B total payments (float vs exact decimal) |
| Duplicate loan ids | 0 |
| Nulls on key columns | 0, except DTI 1,711 and annual income 4 |
| Resolved-loan charge-off rate | 19.96% on standard statuses (268,559 of 1,345,310); 19.98% once "does not meet credit policy" loans are folded in (see Step 2) |

**Source vs RAW reconciliation (8/8 PASS)**
![Reconciliation](images/01_recon_pass.png)

**Loan status mix**
![Status mix](images/02_status_mix.png)

**Volume by origination year**
![Volume by year](images/03_volume_by_year.png)

**Data quality on key columns**
![Data quality, part 1](images/04_data_quality_a.png)
![Data quality, part 2](images/04_data_quality_b.png)

### Design choices (worth saying in an interview)
- **RAW is all VARCHAR.** No type casting at load, so nothing gets silently dropped or coerced. Typing happens in STAGING, where bad values are counted, not lost.
- **Lineage columns** on every row: `_BATCH_ID`, `_SOURCE_FILE`, `_SOURCE_ROW_NUMBER`, `_LOADED_AT`.
- **Source profile captured independently** (pandas, outside Snowflake) and stored in `AUDIT.SOURCE_PROFILE`, so Step 2 reconciliation compares two independent counts, not Snowflake against itself.
- **Key-pair auth** via a dedicated `TYPE = SERVICE` user; the private key never leaves the laptop.
- **COPY results logged** to `AUDIT.LOAD_LOG` (rows parsed, rows loaded, errors).

## Step 2: STAGING + star schema + end-to-end reconciliation

| # | File | What it builds |
|---|------|----------------|
| 1 | `sql/02_staging.sql` | `STAGING.STG_LOANS`: typed and cleaned, 33 junk rows excluded, deduped on loan id, 10 raw statuses mapped to 7 risk groups, risk flags (`IS_RESOLVED`, `IS_BAD`, `IS_DELINQUENT`, `IS_30PLUS_DPD`), gross and net charge-off amounts |
| 2 | `sql/03_marts.sql` | `MARTS.DIM_DATE` (daily calendar 2007 to 2020), `MARTS.DIM_BORROWER` (borrower profile at origination with FICO, income, DTI and tenure bands), `MARTS.FCT_LOAN` (one row per loan, keys to both dimensions) |
| 3 | `sql/04_recon.sql` | 16 PASS/FAIL controls SOURCE → RAW → STAGING → MARTS, written to `AUDIT.RECON_RESULTS` |

### Step 2 results
| Check | Result |
|---|---|
| Loans in STAGING and FCT_LOAN | 2,260,668 (unique, 0 duplicates) |
| Loan amount carried through every layer | $34,016,115,925 (exact match) |
| Net charge-offs (after recoveries net of fees) | $2.73B |
| Unmapped loan statuses | 0 |
| Orphan keys (borrower, issue date) | 0 / 0 |
| End-to-end reconciliation | **16/16 PASS** |
| Resolved-loan charge-off rate | 19.98% (269,320 of 1,348,059) |

**Charge-off rate by FICO band (resolved loans)**
| FICO band | Borrowers | Charge-off rate |
|---|---|---|
| Under 660 | 489 | 30.88% |
| 660 to 699 | 1,304,313 | 23.60% |
| 700 to 739 | 673,794 | 16.08% |
| 740+ | 282,072 | 9.65% |

The 660 to 699 band holds 58% of borrowers and charges off at 2.4x the rate of 740+.

**Note on the borrower dimension:** LendingClub anonymizes member ids, so `DIM_BORROWER` is the borrower profile at origination, 1:1 with the loan.

## Project layout
```
scripts/   Python: download, profile, load, shared Snowflake connection
sql/       Snowflake setup, RAW checks, staging, star schema, reconciliation
data/      local data (git-ignored)
```
