# Databricks notebook source
# -----------------------------------------------------
# 🧩 CONFIGURATION
# -----------------------------------------------------
from pyspark.sql import SparkSession
from datetime import datetime
import requests
import json
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from tenacity import retry, stop_after_attempt, wait_exponential

spark = SparkSession.builder.getOrCreate()

# Databricks job parameters (can be set in job config UI)
dbutils.widgets.text("BASE_URL", "https://api.example.com")
dbutils.widgets.text("API_TOKEN", "")
dbutils.widgets.text("TARGET_PATH", "/mnt/bronze/api_data")
dbutils.widgets.text("CONTROL_TABLE", "metadata.control_api_ingestion")
dbutils.widgets.text("DATE", datetime.utcnow().strftime("%Y-%m-%d"))

BASE_URL = dbutils.widgets.get("BASE_URL")
API_TOKEN = dbutils.widgets.get("API_TOKEN")
TARGET_PATH = dbutils.widgets.get("TARGET_PATH")
CONTROL_TABLE = dbutils.widgets.get("CONTROL_TABLE")
RUN_DATE = dbutils.widgets.get("DATE")

headers = {"Authorization": f"Bearer {API_TOKEN}"} if API_TOKEN else {}


def fetch_metadata():
    metadata_url = f"{BASE_URL}/metadata?date={RUN_DATE}"
    resp = requests.get(metadata_url, headers=headers, timeout=30)
    resp.raise_for_status()
    return resp.json()

metadata = fetch_metadata()
params = [item["id"] for item in metadata.get("items", [])]
print(f"Fetched metadata for {len(params)} parameters.")

if not params:
    raise ValueError("No metadata found for the given date.")


@retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=2, max=20))
def fetch_data(param):
    url = f"{BASE_URL}/data/{param}"
    r = requests.get(url, headers=headers, timeout=15)
    r.raise_for_status()
    data = r.json()
    data["source_id"] = param
    return data

# -----------------------------------------------------
# 🧵 STEP 3: PARALLEL FETCH FROM SECOND ENDPOINT
# -----------------------------------------------------
results = []
failures = []

with ThreadPoolExecutor(max_workers=10) as executor:
    futures = {executor.submit(fetch_data, p): p for p in params}
    for f in as_completed(futures):
        param = futures[f]
        try:
            data = f.result()
            results.append(data)
        except Exception as e:
            print(f"❌ Failed for {param}: {e}")
            failures.append(param)
        time.sleep(0.1)  # mild rate-limit buffer

print(f"✅ Successfully fetched {len(results)} / {len(params)}")


if results:
    df = spark.createDataFrame(results)
    from pyspark.sql.functions import current_timestamp, lit

    df = (
        df.withColumn("ingested_at", current_timestamp())
          .withColumn("run_date", lit(RUN_DATE))
    )

    # Write to Delta/Iceberg
    df.write.format("delta").mode("append").save(TARGET_PATH)

    print(f"✅ Written {df.count()} records to {TARGET_PATH}")
else:
    print("⚠️ No successful results to write.")


metrics = [
    {
        "run_date": RUN_DATE,
        "run_timestamp": datetime.utcnow().isoformat(),
        "params_total": len(params),
        "params_success": len(results),
        "params_failed": len(failures),
        "target_path": TARGET_PATH,
    }
]

metrics_df = spark.createDataFrame(metrics)
metrics_df.write.format("delta").mode("append").saveAsTable(CONTROL_TABLE)

print(f"🧾 Logged run metrics to {CONTROL_TABLE}")

# -----------------------------------------------------
# ✅ DONE
# -----------------------------------------------------
print("🎉 API ingestion job completed successfully.")
