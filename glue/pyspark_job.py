import sys
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.utils import getResolvedOptions

args = getResolvedOptions(sys.argv, ['JOB_NAME', 'output_path'])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session

# Dummy DataFrame
data = [("Alice", 10), ("Bob", 20), ("Charlie", 30)]
columns = ["name", "value"]
df = spark.createDataFrame(data, columns)

output_path = args["output_path"]
df.write.mode("overwrite").parquet(output_path)

print(f"✅ Wrote dummy data to {output_path}")
