"""Step 1a: download LendingClub accepted loans (2007-2018Q4) from Kaggle.

Dataset: https://www.kaggle.com/datasets/wordsforthewise/lending-club
Needs ~/.kaggle/kaggle.json (Kaggle → Settings → Create New Token).
Leaves data/accepted_2007_to_2018Q4.csv.gz (kept gzipped: Snowflake loads .gz directly).
"""
import os
import shutil
from pathlib import Path

from dotenv import load_dotenv
from kaggle.api.kaggle_api_extended import KaggleApi

load_dotenv()
DATA_DIR = Path(os.getenv("DATA_DIR", "data"))
DATASET = "wordsforthewise/lending-club"
TARGET = DATA_DIR / "accepted_2007_to_2018Q4.csv.gz"


def main():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if TARGET.exists():
        print(f"Already have {TARGET} ({TARGET.stat().st_size / 1e6:,.0f} MB); skipping download.")
        return

    api = KaggleApi()
    api.authenticate()
    dl_dir = DATA_DIR / "_kaggle"
    print(f"Downloading {DATASET} → {dl_dir} (accepted + rejected files, ~1.6 GB)...")
    api.dataset_download_files(DATASET, path=str(dl_dir), unzip=True, quiet=False)

    # The archive nests files in folders named like the files; find the accepted file wherever it lands.
    hits = sorted(p for p in dl_dir.rglob("accepted_2007_to_2018*.csv*") if p.is_file())
    if not hits:
        raise SystemExit(f"Could not find the accepted-loans file under {dl_dir}. Contents: {list(dl_dir.rglob('*'))}")
    src = hits[0]
    final = TARGET if src.suffix == ".gz" else DATA_DIR / "accepted_2007_to_2018Q4.csv"
    shutil.move(str(src), final)
    shutil.rmtree(dl_dir, ignore_errors=True)  # drop the rejected-loans file; not used
    print(f"Ready: {final} ({final.stat().st_size / 1e6:,.0f} MB)")


if __name__ == "__main__":
    main()
