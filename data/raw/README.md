# Raw data (not committed)

This folder holds the nine original CSV files of the
[Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)
(licence CC BY-NC-SA 4.0). They are excluded from git by `.gitignore` and are **never modified** by the project.

## Get the files
Automatic (Kaggle public endpoint):
```bash
python scripts/download_data.py
```

Manual, if the automatic download fails:
1. Open the Kaggle page above (a free account is required) and click **Download**.
2. Extract `archive.zip` so that these files sit directly in `data/raw/`:

| File | Rows (excl. header) |
|---|---:|
| olist_customers_dataset.csv | 99,441 |
| olist_geolocation_dataset.csv | 1,000,163 |
| olist_order_items_dataset.csv | 112,650 |
| olist_order_payments_dataset.csv | 103,886 |
| olist_order_reviews_dataset.csv | 99,224 |
| olist_orders_dataset.csv | 99,441 |
| olist_products_dataset.csv | 32,951 |
| olist_sellers_dataset.csv | 3,095 |
| product_category_name_translation.csv | 71 |

`scripts/build_database.py` checks these exact row counts and stops if they differ.
