# Snowflake Data Pipeline -- Setup Guide

A complete, step-by-step guide to build a data pipeline that:

1. Auto-ingests CSV files from **AWS S3** into **Snowflake** using **Snowpipe**
2. Transforms raw data into analytics-ready tables using **dbt**
3. Manages infrastructure with **Terraform**
4. Automates testing and deployment with **GitHub Actions** CI/CD

---

## Table of Contents

| Phase | Steps | What You Will Do |
|-------|-------|------------------|
| **Phase 1: Foundations** | Steps 1--3 | Install tools, generate keys, create Snowflake user |
| **Phase 2: AWS Setup** | Steps 4--5 | Create S3 bucket, IAM role with S3 permissions |
| **Phase 3: Infrastructure** | Steps 6--8 | Configure and deploy Terraform, link AWS to Snowflake |
| **Phase 4: Data Ingestion** | Step 9 | Upload CSV to S3, verify Snowpipe auto-loads data |
| **Phase 5: Transformations** | Steps 10--11 | Configure dbt, run models and tests |
| **Phase 6: CI/CD** | Steps 12--13 | Push to GitHub, set up GitHub Actions pipelines |
| **Phase 7: Validation** | Step 14 | End-to-end verification |

---

## Architecture Overview

```
CSV file uploaded to S3
        |
        v
S3 Event Notification --> SQS Queue
                               |
                               v
                         Snowpipe (auto-ingest)
                               |
                               v
                   BOOKING_RAW table (all VARCHAR)
                               |
                          dbt run
                               |
                   +-----------+-----------+
                   v                       v
           stg_bookings              dim_bookings
           (view: clean &            (table: business
            cast types)               logic & metrics)
                                           |
                                           v
                                   BI Tools / Reports
```

**Key design decisions:**
- All raw columns are `VARCHAR` to avoid Snowflake provider bugs with column collation. Type casting is handled in dbt staging models.
- RSA key-pair authentication is used everywhere (Terraform, dbt, CI/CD). No passwords.

---

## Project Structure

```
Snow_project_v1/
|-- .github/
|   |-- workflows/
|       |-- terraform.yml         # CI: validates Terraform on push
|       |-- dbt.yml               # CI/CD: compiles, runs, and tests dbt models
|-- terraform/
|   |-- main.tf                   # All Snowflake resources (7 resources)
|   |-- variables.tf              # Variable definitions
|   |-- outputs.tf                # Post-deploy instructions
|   |-- terraform.tfvars.example  # Config template (copy to terraform.tfvars)
|   |-- trust-policy.json         # AWS IAM trust policy reference
|-- dbt/
|   |-- dbt_project.yml           # dbt project config
|   |-- packages.yml              # External packages (dbt_utils, dbt_expectations)
|   |-- profiles.yml.example      # Connection template (copy to ~/.dbt/profiles.yml)
|   |-- models/
|       |-- staging/
|       |   |-- sources.yml       # Raw source definitions & data tests
|       |   |-- stg_bookings.sql  # Staging: cleans & casts raw data
|       |-- marts/
|           |-- dim_bookings.sql  # Mart: enriched analytics table
|           |-- schema.yml        # Model tests & documentation
|-- snowflake_key/                # RSA keys (DO NOT COMMIT)
|   |-- rsa_key.p8               # Encrypted private key
|   |-- rsa_key.pub              # Public key
|-- test_data/
|   |-- test_booking_1.csv       # Sample CSV files for testing
|-- .gitignore                   # Prevents secrets from being committed
|-- SETUP_GUIDE.md               # This file
```

---

## CSV File Format

Your CSV files must have this exact header row and column order:

```csv
booking_id,listing_id,host_id,guest_id,check_in_date,check_out_date,total_price,currency,booking_status,created_at
BK001,LST001,HOST001,GUEST001,15/03/24,18/03/24,450,USD,confirmed,01/03/24
BK002,LST002,HOST002,GUEST002,20/03/24,22/03/24,280,USD,pending,05/03/24
```

| Column | Example | Notes |
|--------|---------|-------|
| booking_id | BK001 | Unique per booking |
| listing_id | LST001 | Property identifier |
| host_id | HOST001 | Host identifier |
| guest_id | GUEST001 | Guest identifier |
| check_in_date | 15/03/24 | Format: DD/MM/YY |
| check_out_date | 18/03/24 | Format: DD/MM/YY |
| total_price | 450 | Numeric value |
| currency | USD | Currency code |
| booking_status | confirmed | One of: confirmed, pending, cancelled, completed |
| created_at | 01/03/24 | Format: DD/MM/YY |

Sample files are available in the `test_data/` folder.

---

# Phase 1: Foundations

## Step 1: Install Required Tools

You need three tools installed on your machine.

### 1a. Install Terraform

Terraform manages the Snowflake infrastructure (database, tables, pipes, etc.).

```bash
# macOS
brew install terraform

# Verify installation
terraform --version
```

Expected output: `Terraform v1.x.x`

### 1b. Install dbt with the Snowflake Adapter

dbt transforms the raw data into clean, analytics-ready tables.

```bash
pip install dbt-snowflake

# Verify installation
dbt --version
```

Expected output: Shows `dbt-core` and `dbt-snowflake` versions.

### 1c. Install AWS CLI (Optional)

Only needed if you want to upload CSV files from the command line.

```bash
brew install awscli

# Configure with your AWS credentials
aws configure
```

---

## Step 2: Generate RSA Key-Pair for Snowflake Authentication

Snowflake uses RSA key-pair authentication instead of passwords. You will generate a private key (kept secret) and a public key (registered in Snowflake).

### 2a. Create the Key Directory

Run these commands from the project root (`Snow_project_v1/`):

```bash
mkdir -p snowflake_key
cd snowflake_key
```

### 2b. Generate the Private Key

```bash
openssl genrsa 2048 | openssl pkcs8 -topk8 -v2 des3 -inform PEM -out rsa_key.p8
```

You will be prompted to set a **passphrase**. Choose a strong one and **write it down** -- you will need it in Steps 6 and 10.

### 2c. Generate the Public Key

```bash
openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub
```

Enter the same passphrase you set above.

### 2d. Go Back to the Project Root

```bash
cd ..
```

### 2e. Verify Your Keys

You should now have two files:

| File | Purpose | Keep Secret? |
|------|---------|--------------|
| `snowflake_key/rsa_key.p8` | Encrypted private key | YES -- never commit |
| `snowflake_key/rsa_key.pub` | Public key | Shared with Snowflake |

---

## Step 3: Create a Snowflake User and Register the Public Key

### 3a. Create a Dedicated User in Snowflake

Log into **Snowflake** (Snowsight web UI) as `ACCOUNTADMIN` and run:

```sql
CREATE USER TF_USER
  DEFAULT_ROLE = ACCOUNTADMIN
  DEFAULT_WAREHOUSE = COMPUTE_WH
  COMMENT = 'Service account for Terraform and dbt';

GRANT ROLE ACCOUNTADMIN TO USER TF_USER;
```

### 3b. Get Your Public Key Content

On your local machine, run:

```bash
cat snowflake_key/rsa_key.pub
```

This will output something like:

```
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...
...multiple lines of text...
-----END PUBLIC KEY-----
```

Copy **only the key content** -- everything between the `BEGIN` and `END` lines, **without** those lines, and **without** any line breaks. It should be one single long string.

### 3c. Register the Public Key with the Snowflake User

Run this in Snowflake, pasting your key string:

```sql
ALTER USER TF_USER SET RSA_PUBLIC_KEY='MIIBIjANBgkqh...paste_your_full_key_here...';
```

### 3d. Verify the Key Was Registered

```sql
DESC USER TF_USER;
```

Look for the `RSA_PUBLIC_KEY_FP` row. If it shows a fingerprint value (like `SHA256:abc123...`), the key is successfully registered.

---

# Phase 2: AWS Setup

## Step 4: Create an S3 Bucket

### 4a. Create the Bucket

1. Go to **AWS Console > S3 > Create bucket**
2. Bucket name: choose a globally unique name (e.g., `snowflakedevops`)
3. Region: pick one close to your Snowflake account
4. Leave other settings as default
5. Click **Create bucket**

### 4b. Create the Booking Folder

1. Open your new bucket
2. Click **Create folder**
3. Folder name: `Booking`
4. Click **Create folder**

Your CSV files will be uploaded to `s3://YOUR_BUCKET_NAME/Booking/`.

---

## Step 5: Create an AWS IAM Role for Snowflake

Snowflake needs permission to read files from your S3 bucket. You will create an IAM role that Snowflake can assume.

### 5a. Create the IAM Role

1. Go to **AWS Console > IAM > Roles > Create role**
2. Trusted entity type: select **AWS account**
3. Select **This account** (your own AWS account ID)
4. Click **Next**
5. Skip adding permissions for now (we will add them next)
6. Role name: `snowflake-s3-access-role`
7. Click **Create role**

### 5b. Add S3 Read Permissions

1. Open the role you just created
2. Go to **Permissions** tab > **Add permissions** > **Create inline policy**
3. Click the **JSON** tab and paste this (replace `YOUR_BUCKET_NAME` with your actual bucket name):

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
        "arn:aws:s3:::YOUR_BUCKET_NAME",
        "arn:aws:s3:::YOUR_BUCKET_NAME/*"
      ]
    }
  ]
}
```

4. Policy name: `snowflake-s3-read-policy`
5. Click **Create policy**

### 5c. Copy the Role ARN

From the role summary page, copy the **Role ARN**. It looks like:

```
arn:aws:iam::123456789012:role/snowflake-s3-access-role
```

Save this -- you will need it in Step 6.

---

# Phase 3: Infrastructure

## Step 6: Configure Terraform

### 6a. Create Your Variables File

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

### 6b. Edit `terraform.tfvars`

Open `terraform/terraform.tfvars` in your editor and fill in your values:

```hcl
# Environment
environment  = "dev"
project_name = "airbnb"

# Snowflake Connection
snowflake_organization_name      = "YOUR_ORG"       # First part of your account ID
snowflake_account_name           = "YOUR_ACCOUNT"    # Second part of your account ID
snowflake_user                   = "TF_USER"
snowflake_role                   = "ACCOUNTADMIN"
snowflake_warehouse              = "COMPUTE_WH"
snowflake_private_key_path       = "../snowflake_key/rsa_key.p8"
snowflake_private_key_passphrase = "YOUR_PASSPHRASE" # From Step 2b

# Database
database_name   = "AIRBNB_PROJECT"
raw_schema_name = "RAW"

# AWS S3
s3_bucket_name = "YOUR_BUCKET_NAME"                  # From Step 4
s3_bucket_path = "Booking/"
s3_bucket_url  = "s3://YOUR_BUCKET_NAME/Booking/"
aws_role_arn   = "arn:aws:iam::YOUR_ACCOUNT_ID:role/snowflake-s3-access-role"  # From Step 5c

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

**How to find your Snowflake account identifiers:**
- Log into Snowflake (Snowsight)
- Click on your account name in the bottom-left corner
- Your account URL will be like `https://ORGNAME-ACCOUNTNAME.snowflakecomputing.com`
- `snowflake_organization_name` = the part before the dash (e.g., `HHMNKHZ`)
- `snowflake_account_name` = the part after the dash (e.g., `QIC56996`)

---

## Step 7: Deploy Snowflake Infrastructure with Terraform

### 7a. Initialize Terraform

This downloads the Snowflake provider plugin.

```bash
cd terraform

terraform init
```

Expected: `Terraform has been successfully initialized!`

### 7b. Preview the Plan

This shows what Terraform will create **without** making any changes.

```bash
terraform plan
```

Expected: `Plan: 7 to add, 0 to change, 0 to destroy.`

The 7 resources are:

| # | Resource | Name |
|---|----------|------|
| 1 | Database | `AIRBNB_PROJECT_DEV` |
| 2 | Schema | `RAW` |
| 3 | Storage Integration | `AIRBNB_S3_INT_DEV` |
| 4 | File Format | `AIRBNB_CSV_FORMAT_DEV` |
| 5 | External Stage | `AIRBNB_S3_STAGE_DEV` |
| 6 | Table | `BOOKING_RAW` |
| 7 | Snowpipe | `AIRBNB_BOOKING_PIPE_DEV` |

### 7c. Apply the Plan

This creates all the resources in Snowflake.

```bash
terraform apply
```

Type `yes` when prompted.

Expected output:

```
Apply complete! Resources: 7 added, 0 changed, 0 destroyed.

Outputs:
database_name = "AIRBNB_PROJECT_DEV"
pipe_full_name = "AIRBNB_PROJECT_DEV.RAW.AIRBNB_BOOKING_PIPE_DEV"
```

It will also print **Next Steps** instructions for completing the AWS integration (Step 8).

---

## Step 8: Link AWS and Snowflake (Trust Policy + Event Notification)

After Terraform creates the storage integration, you need to tell AWS to trust Snowflake. This is a one-time manual step.

### 8a. Get Snowflake Integration Details

Run this in **Snowflake**:

```sql
DESCRIBE INTEGRATION AIRBNB_S3_INT_DEV;
```

From the results, copy these two values:

| Property | Example Value |
|----------|---------------|
| `STORAGE_AWS_IAM_USER_ARN` | `arn:aws:iam::629236738139:user/2eih1000-s` |
| `STORAGE_AWS_EXTERNAL_ID` | `UC92399_SFCRole=5_rj+eeAZnOL7+rVhVBTkuDu3UnQs=` |

### 8b. Update the AWS IAM Trust Policy

1. Go to **AWS Console > IAM > Roles > snowflake-s3-access-role**
2. Click the **Trust relationships** tab
3. Click **Edit trust policy**
4. Replace the entire content with this, substituting your values:

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

5. Click **Update policy**

### 8c. Get the Snowpipe SQS ARN

Run this in **Snowflake**:

```sql
SHOW PIPES IN SCHEMA AIRBNB_PROJECT_DEV.RAW;
```

From the results, copy the `notification_channel` value. It will look like:
`arn:aws:sqs:us-east-1:123456789:sf-snowpipe-...`

### 8d. Configure S3 Event Notification

This tells S3 to notify Snowpipe whenever a new file is uploaded.

1. Go to **AWS Console > S3 > YOUR_BUCKET > Properties**
2. Scroll down to **Event notifications**
3. Click **Create event notification**
4. Fill in:

| Setting | Value |
|---------|-------|
| Event name | `snowpipe-booking-notification` |
| Prefix | `Booking/` |
| Event types | Check **All object create events** |
| Destination | Select **SQS queue** |
| SQS queue ARN | Paste the `notification_channel` from Step 8c |

5. Click **Save changes**

### 8e. Verify the Integration

Run in **Snowflake**:

```sql
-- Should return a JSON with executionState = "RUNNING"
SELECT SYSTEM$PIPE_STATUS('AIRBNB_PROJECT_DEV.RAW.AIRBNB_BOOKING_PIPE_DEV');
```

If `executionState` shows `RUNNING`, the integration is complete.

---

# Phase 4: Data Ingestion

## Step 9: Test Snowpipe Auto-Ingestion

### 9a. Upload a Test CSV File

**Option A -- AWS CLI:**

```bash
aws s3 cp test_data/test_booking_1.csv s3://YOUR_BUCKET_NAME/Booking/
```

**Option B -- AWS Console:**
1. Go to S3 > your bucket > `Booking/` folder
2. Click **Upload**
3. Select a CSV file from the `test_data/` folder
4. Click **Upload**

### 9b. Wait 1--2 Minutes

Snowpipe processes files asynchronously. It typically takes 30 seconds to 2 minutes.

### 9c. Verify Data Was Loaded

Run in **Snowflake**:

```sql
-- Check the row count
SELECT COUNT(*) FROM AIRBNB_PROJECT_DEV.RAW.BOOKING_RAW;

-- View the actual data
SELECT * FROM AIRBNB_PROJECT_DEV.RAW.BOOKING_RAW;
```

You should see your CSV rows loaded into the table.

### 9d. Troubleshooting -- If No Data Appears

```sql
-- Check pipe status (should show executionState = RUNNING)
SELECT SYSTEM$PIPE_STATUS('AIRBNB_PROJECT_DEV.RAW.AIRBNB_BOOKING_PIPE_DEV');

-- Check for load errors in the last hour
SELECT *
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'AIRBNB_PROJECT_DEV.RAW.BOOKING_RAW',
    START_TIME => DATEADD(HOURS, -1, CURRENT_TIMESTAMP())
))
ORDER BY LAST_LOAD_TIME DESC;

-- Force Snowpipe to re-scan for files
ALTER PIPE AIRBNB_PROJECT_DEV.RAW.AIRBNB_BOOKING_PIPE_DEV REFRESH;
```

**Common issues:**
- **S3 event notification not configured**: Go back to Step 8d
- **Trust policy incorrect**: Go back to Step 8b
- **File already processed**: Snowpipe skips files it has already loaded. Upload a file with a **different filename**

---

# Phase 5: Data Transformations

## Step 10: Configure dbt

### 10a. Create the dbt Profile Directory

```bash
mkdir -p ~/.dbt
```

### 10b. Create `~/.dbt/profiles.yml`

Create the file `~/.dbt/profiles.yml` with this content (replace the placeholder values):

```yaml
airbnb_analytics:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: YOUR_ORG-YOUR_ACCOUNT          # e.g., HHMNKHZ-QIC56996
      user: TF_USER
      authenticator: snowflake_jwt
      private_key_path: /FULL/PATH/TO/Snow_project_v1/snowflake_key/rsa_key.p8
      private_key_passphrase: "YOUR_PASSPHRASE"
      role: ACCOUNTADMIN
      warehouse: COMPUTE_WH
      database: AIRBNB_PROJECT_DEV
      schema: RAW
      threads: 4
```

**Important notes:**
- `account` format is `ORG_NAME-ACCOUNT_NAME` (with a hyphen), the same values from Step 6b
- `private_key_path` must be an **absolute path** (starts with `/`), not a relative path
- `private_key_passphrase` is the passphrase you set in Step 2b
- A template is available at `dbt/profiles.yml.example`

### 10c. Test the Connection

```bash
cd dbt
dbt debug
```

Expected output (last lines):

```
  Connection test: [OK connection ok]

All checks passed!
```

If you see errors, double-check:
- Is the Snowflake user correct? (`TF_USER`)
- Is the private key path an absolute path?
- Is the passphrase correct?
- Was the public key registered in Snowflake? (Step 3c)

---

## Step 11: Run dbt Models and Tests

### 11a. Install dbt Packages

```bash
cd dbt
dbt deps
```

This installs `dbt_utils` and `dbt_expectations` packages defined in `packages.yml`.

### 11b. Run the Models

```bash
dbt run
```

Expected output:

```
1 of 2 START sql view model RAW_STAGING.stg_bookings ............. [SUCCESS]
2 of 2 START sql table model RAW_ANALYTICS.dim_bookings .......... [SUCCESS]

Completed successfully
Done. PASS=2 WARN=0 ERROR=0 SKIP=0 TOTAL=2
```

This creates two objects in Snowflake:

| Object | Schema | Type | What It Does |
|--------|--------|------|--------------|
| `stg_bookings` | `RAW_STAGING` | View | Cleans raw VARCHAR data: trims whitespace, casts dates and numbers, flags invalid records |
| `dim_bookings` | `RAW_ANALYTICS` | Table | Enriched analytics table: calculates price per night, revenue, stay categories, lead time, time dimensions |

### 11c. Run the Tests

```bash
dbt test
```

Expected output:

```
Completed successfully
Done. PASS=19 WARN=0 ERROR=0 SKIP=0 TOTAL=19
```

The 19 tests check things like:
- `booking_id` and `booking_key` are unique and not null
- `booking_status` only contains valid values (confirmed, pending, cancelled, completed)
- `nights_booked` is non-negative
- `check_out_date` is after `check_in_date`
- `stay_category` only contains valid labels

### 11d. Verify in Snowflake

```sql
-- Staging: cleaned data (view)
SELECT * FROM AIRBNB_PROJECT_DEV.RAW_STAGING.STG_BOOKINGS LIMIT 5;

-- Marts: enriched analytics data (table)
SELECT * FROM AIRBNB_PROJECT_DEV.RAW_ANALYTICS.DIM_BOOKINGS LIMIT 5;

-- Sample analytics query
SELECT
    booking_status_display,
    stay_category,
    COUNT(*) AS total_bookings,
    SUM(realized_revenue) AS total_revenue,
    ROUND(AVG(price_per_night), 2) AS avg_price_per_night
FROM AIRBNB_PROJECT_DEV.RAW_ANALYTICS.DIM_BOOKINGS
GROUP BY 1, 2
ORDER BY total_bookings DESC;
```

---

# Phase 6: CI/CD with GitHub Actions

## Step 12: Push the Project to GitHub

### 12a. Create a GitHub Repository

1. Go to [github.com/new](https://github.com/new)
2. Repository name: e.g., `Snowflake-Devops`
3. Visibility: Private (recommended, since it connects to your cloud accounts)
4. Do **not** initialize with a README (you already have files)
5. Click **Create repository**

### 12b. Initialize Git and Push

From the project root (`Snow_project_v1/`):

```bash
git init
git add .
git commit -m "Initial commit: Snowflake data pipeline"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/YOUR_REPO.git
git push -u origin main
```

**Verify**: The `.gitignore` ensures that secrets (`rsa_key.p8`, `terraform.tfvars`, `terraform.tfstate`) are **not** pushed.

### 12c. Create a GitHub Personal Access Token (PAT)

1. Go to **GitHub > Settings > Developer settings > Personal access tokens > Tokens (classic)**
2. Click **Generate new token (classic)**
3. Name: `snowflake-devops`
4. Select these scopes:
   - `repo` (full control of private repositories)
   - `workflow` (required to push workflow files)
5. Click **Generate token**
6. Copy the token immediately (you won't see it again)

If you already have a PAT but get errors pushing `.github/workflows/` files, make sure the `workflow` scope is enabled.

---

## Step 13: Configure GitHub Actions

### 13a. Add GitHub Secrets

Go to **GitHub > Your Repository > Settings > Secrets and variables > Actions > Secrets > New repository secret**

Add these secrets one by one:

| Secret Name | Value | How to Get It |
|-------------|-------|---------------|
| `SNOWFLAKE_ORG_NAME` | Your Snowflake org name | e.g., `HHMNKHZ` (from Step 6b) |
| `SNOWFLAKE_ACCOUNT_NAME` | Your Snowflake account name | e.g., `QIC56996` (from Step 6b) |
| `SNOWFLAKE_USER` | `TF_USER` | The user from Step 3a |
| `SNOWFLAKE_PRIVATE_KEY` | Contents of `rsa_key.p8` | Run `cat snowflake_key/rsa_key.p8` and copy the entire output including the BEGIN/END lines |
| `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE` | Your key passphrase | From Step 2b |
| `AWS_ROLE_ARN` | Your IAM role ARN | From Step 5c |

### 13b. Add GitHub Variables

Go to **GitHub > Your Repository > Settings > Secrets and variables > Actions > Variables > New repository variable**

Add these variables:

| Variable Name | Value |
|---------------|-------|
| `ENVIRONMENT` | `dev` |
| `ENVIRONMENT_UPPER` | `DEV` |
| `PROJECT_NAME` | `airbnb` |
| `DATABASE_NAME` | `AIRBNB_PROJECT` |
| `S3_BUCKET_NAME` | Your S3 bucket name |
| `S3_BUCKET_PATH` | `Booking/` |
| `S3_BUCKET_URL` | `s3://YOUR_BUCKET_NAME/Booking/` |

### 13c. Create a GitHub Environment

This adds an approval gate before dbt models are deployed to Snowflake.

1. Go to **GitHub > Your Repository > Settings > Environments**
2. Click **New environment**
3. Name: `production`
4. Click **Configure environment**
5. (Optional) Under **Required reviewers**, add yourself so you must approve each deploy

### 13d. How the CI/CD Pipelines Work

There are two workflow files in `.github/workflows/`:

**Terraform Pipeline** (`terraform.yml`) -- triggered by changes to `terraform/` files:

| Step | What It Does |
|------|--------------|
| `terraform init` | Downloads provider plugins |
| `terraform fmt -check` | Checks code formatting |
| `terraform validate` | Validates configuration syntax |

> Note: Terraform `apply` is not run in CI because the state file is stored locally. Run `terraform apply` from your local machine.

**dbt Pipeline** (`dbt.yml`) -- triggered by changes to `dbt/models/`, `dbt_project.yml`, or `packages.yml`:

| Job | Steps | When |
|-----|-------|------|
| **dbt Check** | `dbt compile` | Every push and PR |
| **dbt Deploy** | `dbt run` then `dbt test` | Push to `main` only (requires environment approval) |

The dbt pipeline can also be triggered manually via **Actions > dbt CI/CD > Run workflow**.

### 13e. Verify the Pipelines

Push a small change to trigger the workflows:

```bash
# Make a trivial change (e.g., add a comment to a model file)
git add .
git commit -m "test: verify CI/CD pipeline"
git push
```

Then go to **GitHub > Your Repository > Actions** to watch the workflows run.

---

# Phase 7: Validation

## Step 14: End-to-End Pipeline Verification

Run through this checklist to confirm everything works:

### 14a. Infrastructure Check

```bash
cd terraform
terraform output
```

All 7 resources should be listed.

### 14b. Data Ingestion Check

Upload a new CSV file to S3 and wait 1--2 minutes:

```bash
aws s3 cp test_data/test_booking_1.csv s3://YOUR_BUCKET_NAME/Booking/test_new.csv
```

Then verify in Snowflake:

```sql
SELECT COUNT(*) FROM AIRBNB_PROJECT_DEV.RAW.BOOKING_RAW;
```

### 14c. dbt Models Check

```bash
cd dbt
dbt run && dbt test
```

All models should succeed. All 19 tests should pass.

### 14d. CI/CD Check

Go to **GitHub > Actions** and confirm both workflows show green checkmarks.

### 14e. Full Data Flow Check

Run in **Snowflake** to see data at every layer:

```sql
-- Layer 1: Raw (loaded by Snowpipe)
SELECT 'RAW' AS layer, COUNT(*) AS rows FROM AIRBNB_PROJECT_DEV.RAW.BOOKING_RAW
UNION ALL
-- Layer 2: Staging (cleaned by dbt)
SELECT 'STAGING', COUNT(*) FROM AIRBNB_PROJECT_DEV.RAW_STAGING.STG_BOOKINGS
UNION ALL
-- Layer 3: Analytics (enriched by dbt)
SELECT 'ANALYTICS', COUNT(*) FROM AIRBNB_PROJECT_DEV.RAW_ANALYTICS.DIM_BOOKINGS;
```

---

# Quick Reference

## Terraform Commands

| Task | Command | Run From |
|------|---------|----------|
| Initialize | `terraform init` | `terraform/` |
| Preview changes | `terraform plan` | `terraform/` |
| Deploy | `terraform apply` | `terraform/` |
| Show outputs | `terraform output` | `terraform/` |
| Destroy everything | `terraform destroy` | `terraform/` |
| Format files | `terraform fmt` | `terraform/` |

## dbt Commands

| Task | Command | Run From |
|------|---------|----------|
| Test connection | `dbt debug` | `dbt/` |
| Install packages | `dbt deps` | `dbt/` |
| Run all models | `dbt run` | `dbt/` |
| Run one model | `dbt run --select dim_bookings` | `dbt/` |
| Full refresh | `dbt run --full-refresh` | `dbt/` |
| Run tests | `dbt test` | `dbt/` |
| Compile SQL | `dbt compile` | `dbt/` |
| Generate docs | `dbt docs generate` | `dbt/` |
| View docs | `dbt docs serve` | `dbt/` |

## Snowflake Monitoring Queries

```sql
-- Pipe status
SELECT SYSTEM$PIPE_STATUS('AIRBNB_PROJECT_DEV.RAW.AIRBNB_BOOKING_PIPE_DEV');

-- Recent file loads (last 24 hours)
SELECT *
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'AIRBNB_PROJECT_DEV.RAW.BOOKING_RAW',
    START_TIME => DATEADD(HOURS, -24, CURRENT_TIMESTAMP())
))
ORDER BY LAST_LOAD_TIME DESC;

-- Force Snowpipe to re-scan
ALTER PIPE AIRBNB_PROJECT_DEV.RAW.AIRBNB_BOOKING_PIPE_DEV REFRESH;
```

---

# Troubleshooting

## Terraform Issues

### "JWT token is invalid" or "private key requires a passphrase"

- Make sure `snowflake_private_key_passphrase` is set in `terraform.tfvars`
- Verify your private key: `openssl rsa -in snowflake_key/rsa_key.p8 -check` (enter passphrase)
- Make sure the public key is registered with the Snowflake user (Step 3c)

### "Object already exists" during terraform apply

The resource already exists in Snowflake but is not in Terraform's state. Import it:

```bash
terraform import snowflake_storage_integration.s3 AIRBNB_S3_INT_DEV
```

### "Cannot specify column collation"

Known bug in Snowflake provider v0.87.x. All raw table columns use VARCHAR type to avoid this. Type casting is done in dbt.

### "Error assuming AWS_ROLE"

The AWS IAM trust policy does not match the Snowflake integration. Re-do Step 8a and 8b.

## Snowpipe Issues

### Data not loading after S3 upload

1. Check pipe status: `SELECT SYSTEM$PIPE_STATUS(...)` -- should show `RUNNING`
2. Check S3 event notification is configured (Step 8d)
3. Check IAM trust policy (Step 8b)
4. Try manual refresh: `ALTER PIPE ... REFRESH`
5. Check for errors: query `INFORMATION_SCHEMA.COPY_HISTORY`

### File parsed but 0 rows loaded

Snowpipe skips files it has already processed. Upload a file with a **different filename**.

### Columns and data don't match

The CSV column order must exactly match the table column order. If you change the table schema, you must drop and recreate the table and pipe:

```sql
DROP PIPE AIRBNB_PROJECT_DEV.RAW.AIRBNB_BOOKING_PIPE_DEV;
DROP TABLE AIRBNB_PROJECT_DEV.RAW.BOOKING_RAW;
```

Then remove from Terraform state and re-apply:

```bash
terraform state rm snowflake_pipe.booking
terraform state rm snowflake_table.booking_raw
terraform apply
```

## dbt Issues

### "All checks passed!" fails in dbt debug

- Verify `~/.dbt/profiles.yml` exists and has the correct values
- The `private_key_path` must be an **absolute path** (e.g., `/Users/you/Snow_project_v1/snowflake_key/rsa_key.p8`)
- Delete any `profiles.yml` inside the `dbt/` project folder (dbt should only use `~/.dbt/profiles.yml`)

### dim_bookings table is empty

The staging model filters out invalid records. Check:
- Are dates in `DD/MM/YY` format in your CSV?
- Run `SELECT * FROM RAW_STAGING.STG_BOOKINGS WHERE _is_invalid_record = true` to see filtered rows

### dbt test failures

- Source tests (on `BOOKING_RAW`) use `severity: warn` so they won't block CI
- Mart tests (on `dim_bookings`) use `severity: error` by default
- If you have null `BOOKING_ID` rows, clean them: `DELETE FROM BOOKING_RAW WHERE BOOKING_ID IS NULL`

## GitHub Actions Issues

### Push rejected: "refusing to allow... workflow scope"

Your GitHub Personal Access Token needs the `workflow` scope. Update it at:
**GitHub > Settings > Developer settings > Personal access tokens**

### Terraform workflow fails with "fmt check"

Run `terraform fmt` locally and push the formatted files:

```bash
cd terraform
terraform fmt
git add . && git commit -m "fix: format terraform files" && git push
```

### dbt workflow fails in CI but works locally

- Verify all GitHub Secrets and Variables are set correctly (Step 13a, 13b)
- Check that the `production` environment exists (Step 13c)
- Check the workflow logs: **GitHub > Actions > click the failed run > click the failed job**
