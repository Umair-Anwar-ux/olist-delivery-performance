"""Download the Olist Brazilian E-Commerce dataset from Kaggle into data/raw/.

Usage:  python scripts/download_data.py

Uses Kaggle's public download endpoint (no API key needed at the time of
writing). Existing files are never overwritten. If the download fails, it
prints manual instructions instead (also in data/raw/README.md).
"""
import io
import sys
import urllib.request
import zipfile
from pathlib import Path

URL = "https://www.kaggle.com/api/v1/datasets/download/olistbr/brazilian-ecommerce"
RAW_DIR = Path(__file__).resolve().parents[1] / "data" / "raw"
EXPECTED = {
    "olist_customers_dataset.csv", "olist_geolocation_dataset.csv", "olist_order_items_dataset.csv",
    "olist_order_payments_dataset.csv", "olist_order_reviews_dataset.csv", "olist_orders_dataset.csv",
    "olist_products_dataset.csv", "olist_sellers_dataset.csv", "product_category_name_translation.csv",
}
MANUAL = """
Automatic download failed. Download the files manually:
  1. Open https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce (free Kaggle account required).
  2. Click "Download" to get archive.zip (~45 MB).
  3. Extract the nine CSV files into data/raw/ (no sub-folder):
     """ + "\n     ".join(sorted(EXPECTED)) + """
  4. Run: python scripts/build_database.py
Alternative with the Kaggle CLI (needs ~/.kaggle/kaggle.json):
  kaggle datasets download -d olistbr/brazilian-ecommerce -p data/raw --unzip
"""


def main() -> None:
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    present = {p.name for p in RAW_DIR.glob("*.csv")}
    if EXPECTED <= present:
        print("All nine raw files already present in data/raw/ - nothing to do.")
        return
    try:
        print(f"Downloading {URL} ...")
        with urllib.request.urlopen(URL, timeout=300) as resp:
            payload = resp.read()
        archive = zipfile.ZipFile(io.BytesIO(payload))
    except Exception as exc:  # network error, auth wall, not a zip, ...
        sys.exit(f"{exc}\n{MANUAL}")

    for member in archive.namelist():
        name = Path(member).name
        if name not in EXPECTED:
            continue
        target = RAW_DIR / name
        if target.exists():
            print(f"  keep existing {name}")
            continue
        target.write_bytes(archive.read(member))
        print(f"  wrote {name}")
    missing = EXPECTED - {p.name for p in RAW_DIR.glob("*.csv")}
    if missing:
        sys.exit(f"Archive did not contain: {sorted(missing)}\n{MANUAL}")
    print("Done.")


if __name__ == "__main__":
    main()
