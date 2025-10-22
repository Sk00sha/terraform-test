import sys
from awsglue.utils import getResolvedOptions

# Glue passes arguments as --key value pairs
args = getResolvedOptions(sys.argv, ['JOB_NAME', 'my_flag'])

my_flag = args['my_flag'].lower() == 'true'

print(f"✅ Starting Glue job: {args['JOB_NAME']}")
print(f"Received my_flag = {my_flag}")

if my_flag:
    print("Doing TRUE branch logic...")
    # Example logic
    # perform_data_load()
else:
    print("Doing FALSE branch logic...")
    # Example logic
    # skip_data_load()

print("✅ Job completed successfully.")
