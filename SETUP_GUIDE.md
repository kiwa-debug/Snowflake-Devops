# Setup Guide: Snowflake Data Pipeline

End-to-end guide to deploy a data pipeline that auto-ingests CSV files from S3 into Snowflake using Snowpipe, transforms data with dbt, and deploys via Bitbucket Pipelines.

**Authentication:** RSA Key-Pair (no passwords)

---

## Table of Contents

1. [Prerequisites](#step-1-prerequisites)
2. [Generate Snowflake RSA Key-Pair](#step-2-generate-snowflake-rsa-key-pair)
3. [Register the Public Key in Snowflake](#step-3-register-the-public-key-in-snowflake)
4. [Create AWS IAM Role](#step-4-create-aws-iam-role)
5. [Configure Terraform](#step-5-configure-terraform)
6. [Deploy Infrastructure](#step-6-deploy-infrastructure)
7. [Complete AWS-Snowflake Integration](#step-7-complete-aws-snowflake-integration)
8. [Test Snowpipe](#step-8-test-snowpipe)
9. [Configure dbt](#step-9-configure-dbt)
10. [Run dbt](#step-10-run-dbt)
11. [Verify the Full Pipeline](#step-11-verify-the-full-pipeline)
12. [Set Up Bitbucket CI/CD](#step-12-set-up-bitbucket-cicd)
13. [Quick Reference](#quick-reference)
14. [Troubleshooting](#troubleshooting)

---

## Step 1: Prerequisites

### Install Tools

```bash
# Terraform
brew install terraform

# dbt with Snowflake adapter
pip install dbt-snowflake

# Verify
terraform --version
dbt --version
```

### What You Need

- Snowflake account with ACCOUNTADMIN access
- AWS account with an S3 bucket (`snowbucketkirtish`)
- CSV files in `s3://snowbucketkirtish/Booking/`

---

## Step 2: Generate Snowflake RSA Key-Pair

Create a folder for your keys and generate them:

```bash
mkdir -p snowflake_key
cd snowflake_key

# Generate encrypted private key (you'll set a passphrase)
openssl genrsa 2048 | openssl pkcs8 -topk8 -v2 des3 -inform PEM -out rsa_key.p8

# Generate public key from the private key
openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub

cd ..
```

You'll be asked to set a **passphrase** -- remember it, you'll need it for Terraform and dbt.

After this you should have:
- `snowflake_key/rsa_key.p8` (encrypted private key)
- `snowflake_key/rsa_key.pub` (public key)

---

## Step 3: Register the Public Key in Snowflake

### 3a. Get the Public Key Value

```bash
cat snowflake_key/rsa_key.pub
```

Copy only the key content (everything between `-----BEGIN PUBLIC KEY-----` and `-----END PUBLIC KEY-----`, without those lines, and without line breaks).

### 3b. Register in Snowflake

Run this in Snowflake (Snowsight or SnowSQL), replacing the key value:

```sql
ALTER USER TERRAFORMUSER SET RSA_PUBLIC_KEY='MIIBIjANBgkqh...paste your key here...';
```

### 3c. Verify It Works

```sql
DESC USER TERRAFORMUSER;
```

Look for `RSA_PUBLIC_KEY_FP` -- if it shows a fingerprint, the key is registered.

---

## Step 4: Create AWS IAM Role

### 4a. Create the Role

1. Go to **AWS Console > IAM > Roles > Create Role**
2. Trusted entity: **AWS Account** (your own account)
3. Role name: `snowflake-s3-access-role`
4. Click **Create Role**

### 4b. Attach S3 Policy

Open the role > **Permissions > Add permissions > Create inline policy** > JSON:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::snowbucketkirtish",
        "arn:aws:s3:::snowbucketkirtish/*"
      ]
    }
  ]
}
```

Policy name: `snowflake-s3-read-policy`

### 4c. Note the Role ARN

Copy it from the role summary page (e.g., `arn:aws:iam::123456789012:role/snowflake-s3-access-role`).

---

## Step 5: Configure Terraform

### 5a. Create Your Variables File

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

### 5b. Edit terraform.tfvars

```hcl
# Environment
environment  = "dev"
project_name = "airbnb"

# Snowflake Connection (Key-Pair Auth - no password needed)
snowflake_account                = "HHMNKHZ-QIC56996"               # Your Snowflake account ID
snowflake_user                   = "TERRAFORMUSER"                  # Your Snowflake username
snowflake_role                   = "ACCOUNTADMIN"
snowflake_warehouse              = "COMPUTE_WH"
snowflake_private_key_path       = "../snowflake_key/rsa_key.p8"    # Path to private key (relative to terraform/)
snowflake_private_key_passphrase = "YOUR_KEY_PASSPHRASE"            # ← Replace with your key passphrase

# Database
database_name   = "AIRBNB_PROJECT"
raw_schema_name = "RAW"

# AWS S3
s3_bucket_name = "snowbucketkirtish"
s3_bucket_path = "Booking/"
s3_bucket_url  = "s3://snowbucketkirtish/Booking/"
aws_role_arn   = "arn:aws:iam::YOUR_ACCOUNT_ID:role/snowflake-s3-access-role"  # ← Replace with your AWS Role ARN

# Snowpipe
auto_ingest_enabled = true
file_format_type    = "CSV"
csv_skip_header     = 1
csv_field_delimiter = ","

# Tags
tags = {
  project     = "airbnb-data-pipeline"
  managed_by  = "terraform"
  cost_center = "data-engineering"
}
```

> **Note:** No `snowflake_password` is needed. Authentication uses the RSA key-pair from `snowflake_key/rsa_key.p8` with the passphrase you set in Step 2.

---

## Step 6: Deploy Infrastructure

```bash
cd terraform

# Initialize
terraform init

# Preview what will be created (7 resources)
terraform plan

# Deploy (type 'yes')
terraform apply
```

**Expected output:**
```
Apply complete! Resources: 7 added, 0 changed, 0 destroyed.

database_name = "AIRBNB_PROJECT_DEV"
pipe_full_name = "AIRBNB_PROJECT_DEV.RAW.AIRBNB_BOOKING_PIPE_DEV"
```

---

## Step 7: Complete AWS-Snowflake Integration

### 7a. Get Storage Integration Details

Run in **Snowflake**:

```sql
DESCRIBE INTEGRATION AIRBNB_S3_INT_DEV;
```

Note these two values:
- `STORAGE_AWS_IAM_USER_ARN`
- `STORAGE_AWS_EXTERNAL_ID`

### 7b. Update AWS IAM Trust Policy

Go to **AWS > IAM > Roles > snowflake-s3-access-role > Trust relationships > Edit**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "PASTE_STORAGE_AWS_IAM_USER_ARN_HERE"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "PASTE_STORAGE_AWS_EXTERNAL_ID_HERE"
        }
      }
    }
  ]
}
```

### 7c. Get Snowpipe SQS ARN

Run in **Snowflake**:

```sql
SHOW PIPES IN SCHEMA AIRBNB_PROJECT_DEV.RAW;
```

Copy the `notification_channel` value.

### 7d. Configure S3 Event Notification

1. **AWS > S3 > snowbucketkirtish > Properties > Event notifications > Create**
2. Configure:

| Setting | Value |
|---------|-------|
| Event name | `snowpipe-booking-notification` |
| Prefix | `Booking/` |
| Event types | All object create events |
| Destination | SQS queue |
| SQS ARN | Paste the `notification_channel` from Step 7c |

---

## Step 8: Test Snowpipe

### 8a. Upload a Test CSV

Create a file with your CSV's column format and upload to S3:

```bash
aws s3 cp test_data/test_booking_3.csv s3://snowbucketkirtish/Booking/
```

Or upload via the AWS Console to `Booking/` folder.

### 8b. Verify (Wait 1-2 Minutes)

```sql
-- Check pipe status
SELECT SYSTEM$PIPE_STATUS('AIRBNB_PROJECT_DEV.RAW.AIRBNB_BOOKING_PIPE_DEV');

-- Check data arrived
SELECT * FROM AIRBNB_PROJECT_DEV.RAW.BOOKING_RAW;
```

### 8c. If No Data Appears

```sql
-- Check for load errors
SELECT *
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'AIRBNB_PROJECT_DEV.RAW.BOOKING_RAW',
    START_TIME => DATEADD(HOURS, -1, CURRENT_TIMESTAMP())
))
ORDER BY LAST_LOAD_TIME DESC;

-- Force a refresh
ALTER PIPE AIRBNB_PROJECT_DEV.RAW.AIRBNB_BOOKING_PIPE_DEV REFRESH;
```

---

## Step 9: Configure dbt

### 9a. Create dbt Profile

```bash
mkdir -p ~/.dbt
```

### 9b. Create ~/.dbt/profiles.yml

```yaml
airbnb_analytics:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: HHMNKHZ-QIC56996                                        # Your Snowflake account ID
      user: TERRAFORMUSER                                              # Your Snowflake username
      authenticator: snowflake_jwt                                     # Key-pair auth (no password)
      private_key_path: /FULL/PATH/TO/snowflake_key/rsa_key.p8        # ← Replace with absolute path
      private_key_passphrase: "YOUR_KEY_PASSPHRASE"                    # ← Replace with your passphrase
      role: ACCOUNTADMIN
      warehouse: COMPUTE_WH
      database: AIRBNB_PROJECT_DEV
      schema: RAW
      threads: 4
```

**Important:** Use the **full absolute path** for `private_key_path` (e.g., `/Users/kirtishwankhedkar/Snowflake personal devops/snowflake_key/rsa_key.p8`).

### 9c. Test Connection

```bash
cd dbt
dbt debug
```

**Expected:** `All checks passed!`

---

## Step 10: Run dbt

```bash
cd dbt

# Install packages
dbt deps

# Run models
dbt run

# Run tests
dbt test
```

**Expected output:**
```
1 of 2 START sql view model RAW_staging.stg_bookings ................ [SUCCESS]
2 of 2 START table model RAW_analytics.dim_bookings ................. [SUCCESS]

Completed successfully
Done. PASS=2 WARN=0 ERROR=0 SKIP=0 TOTAL=2
```

---

## Step 11: Verify the Full Pipeline

Run in **Snowflake**:

```sql
-- Raw data (loaded by Snowpipe)
SELECT COUNT(*) FROM AIRBNB_PROJECT_DEV.RAW.BOOKING_RAW;

-- Staging view (cleaned by dbt)
SELECT * FROM AIRBNB_PROJECT_DEV.RAW_STAGING.STG_BOOKINGS LIMIT 5;

-- Analytics table (enriched by dbt)
SELECT * FROM AIRBNB_PROJECT_DEV.RAW_ANALYTICS.DIM_BOOKINGS LIMIT 5;

-- Sample analytics query
SELECT
    booking_status_display,
    stay_category,
    COUNT(*) as total_bookings,
    SUM(realized_revenue) as total_revenue,
    AVG(price_per_night) as avg_price_per_night
FROM AIRBNB_PROJECT_DEV.RAW_ANALYTICS.DIM_BOOKINGS
GROUP BY 1, 2
ORDER BY total_bookings DESC;
```

---

## Step 12: Set Up Bitbucket CI/CD

### 12a. Push Code to Bitbucket

```bash
git init
git add .
git commit -m "Initial commit: Snowflake data pipeline"

# Set remote (use your repo URL)
git remote add origin git@bitbucket.org:YOUR_WORKSPACE/YOUR_REPO.git

# Push (use 'develop' if 'main' is protected)
git push -u origin develop
```

### 12b. Encode Your Private Key

Run locally:

```bash
base64 -i snowflake_key/rsa_key.p8 | tr -d '\n' | pbcopy
```

This copies the base64-encoded key to your clipboard.

### 12c. Add Repository Variables

Go to **Bitbucket > Your Repo > Settings > Pipelines > Repository Variables**

| Variable | Value | Secured |
|----------|-------|---------|
| `SNOWFLAKE_ACCOUNT` | Your Snowflake account ID | No |
| `SNOWFLAKE_USER` | `TERRAFORMUSER` | No |
| `SNOWFLAKE_PRIVATE_KEY` | *(paste from clipboard -- Step 12b)* | **Yes** |
| `SNOWFLAKE_KEY_PASSPHRASE` | Your private key passphrase | **Yes** |
| `SNOWFLAKE_ROLE` | `ACCOUNTADMIN` | No |
| `SNOWFLAKE_WAREHOUSE` | `COMPUTE_WH` | No |
| `AWS_ROLE_ARN` | Your IAM Role ARN | No |

### 12d. Enable Pipelines

Go to **Bitbucket > Your Repo > Settings > Pipelines > Settings > Enable Pipelines**

### 12e. How the Pipeline Works

The pipeline decodes your base64 private key at runtime, writes it to a temp file, and uses it for both Terraform and dbt. No credentials are stored permanently.

| Push to | What happens | Approval |
|---------|-------------|----------|
| Feature branch | Validate only | Automatic |
| `develop` | Deploy to DEV + run dbt | Automatic |
| `main` | Deploy to PROD + run dbt | **Manual** |
| Pull request | Validate only | Automatic |

### 12f. Test the Pipeline

```bash
git commit --allow-empty -m "test pipeline"
git push origin develop
```

Go to **Bitbucket > Pipelines** to watch it run.

---

## Quick Reference

### Terraform

| Task | Command |
|------|---------|
| Initialize | `terraform init` |
| Preview | `terraform plan` |
| Deploy | `terraform apply` |
| Destroy | `terraform destroy` |
| Show outputs | `terraform output` |

### dbt

| Task | Command |
|------|---------|
| Install packages | `dbt deps` |
| Test connection | `dbt debug` |
| Run all models | `dbt run` |
| Run one model | `dbt run --select dim_bookings` |
| Full refresh | `dbt run --full-refresh` |
| Run tests | `dbt test` |
| Source freshness | `dbt source freshness` |
| Generate docs | `dbt docs generate` |
| View docs | `dbt docs serve` |

### Snowflake Monitoring

```sql
-- Pipe status
SELECT SYSTEM$PIPE_STATUS('AIRBNB_PROJECT_DEV.RAW.AIRBNB_BOOKING_PIPE_DEV');

-- Recent loads
SELECT *
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'AIRBNB_PROJECT_DEV.RAW.BOOKING_RAW',
    START_TIME => DATEADD(HOURS, -24, CURRENT_TIMESTAMP())
))
ORDER BY LAST_LOAD_TIME DESC;

-- Force reload
ALTER PIPE AIRBNB_PROJECT_DEV.RAW.AIRBNB_BOOKING_PIPE_DEV REFRESH;
```

---

## Troubleshooting

### Terraform: "private key requires a passphrase"

Your key is encrypted. Make sure `snowflake_private_key_passphrase` is set in `terraform.tfvars`.

### Terraform: "Cannot specify column collation"

Known bug in Snowflake provider v0.87.x. The raw table uses all-VARCHAR columns to avoid this. Type casting happens in dbt.

### Snowpipe: Data not loading

1. Check pipe status: `SELECT SYSTEM$PIPE_STATUS(...)`
2. Check copy history for errors
3. Verify S3 event notification is configured (Step 7d)
4. Verify IAM trust policy has correct values (Step 7b)
5. Try manual refresh: `ALTER PIPE ... REFRESH`

### Snowpipe: File parsed but 0 rows loaded

The file was already processed or contained duplicate data. Upload a new file with a **different filename** and **different data**.

### dbt: "Env var required but not provided"

dbt is reading a wrong `profiles.yml`. Delete any `profiles.yml` in the `dbt/` project folder. dbt should only read from `~/.dbt/profiles.yml`.

### dbt: dim_bookings is empty

The staging model filters invalid records. Check if your date format matches. The staging model expects dates in `DD/MM/YY` format. If your CSV uses a different format, update the `try_to_date()` calls in `stg_bookings.sql`.

### Bitbucket: "Permission denied to create branch main"

Your repo has branch protection. Push to `develop` instead:

```bash
git checkout -b develop
git push origin develop
```

### Bitbucket: Authentication failed

Use SSH instead of HTTPS:

```bash
git remote set-url origin git@bitbucket.org:WORKSPACE/REPO.git
```

---

## Project Structure

```
├── terraform/
│   ├── main.tf                  # All Snowflake resources
│   ├── variables.tf             # Variable definitions
│   ├── outputs.tf               # Post-deploy instructions
│   └── terraform.tfvars.example # Config template
├── dbt/
│   ├── dbt_project.yml          # Project config
│   ├── packages.yml             # dbt_utils, dbt_expectations
│   ├── profiles.yml.example     # Connection template
│   └── models/
│       ├── staging/
│       │   ├── sources.yml      # Source definitions
│       │   └── stg_bookings.sql # Clean + cast types
│       └── marts/
│           ├── dim_bookings.sql # Business logic
│           └── schema.yml       # Tests + docs
├── snowflake_key/
│   ├── rsa_key.p8               # Private key (DO NOT COMMIT)
│   └── rsa_key.pub              # Public key
├── bitbucket-pipelines.yml      # CI/CD pipeline
├── .gitignore                   # Prevents credential commits
└── README.md
```

## Data Flow

```
CSV uploaded to S3
        │
        ▼
S3 Event Notification ──▶ SQS Queue
                                │
                                ▼
                          Snowpipe (auto-ingest)
                                │
                                ▼
                    BOOKING_RAW (all VARCHAR)
                                │
                           dbt run
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
            stg_bookings              dim_bookings
            (view: clean +            (table: business
             cast types)               logic + metrics)
                                            │
                                            ▼
                                    BI Tools / Reports
```
