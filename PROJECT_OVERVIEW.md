# Project Overview: Airbnb Booking Analytics Pipeline

## What This Project Does

This project takes raw booking data from CSV files and turns it into clean, analytics-ready tables in Snowflake -- automatically.

When someone drops a CSV file into an S3 bucket, the data flows through three layers without any manual work:

1. **Ingestion** -- Snowpipe detects the new file and loads it into Snowflake within minutes
2. **Transformation** -- dbt cleans the raw data, fixes types, and builds enriched analytics tables
3. **Quality checks** -- 19 automated tests verify the data is accurate before anyone queries it

The entire infrastructure is defined as code (Terraform), the transformations are version-controlled (dbt + Git), and changes are validated automatically (GitHub Actions).

---

## Why This Project Exists

### The Problem

Raw booking data arrives as CSV files with inconsistent formatting: dates stored as text, prices without type enforcement, no validation that a checkout date comes after a check-in date, and no way to answer business questions like "what's our average price per night for weekend stays?" without manual Excel work.

### The Solution

This pipeline solves that by creating a structured, automated path from raw files to queryable analytics:

| Without This Pipeline | With This Pipeline |
|-----------------------|--------------------|
| Someone manually uploads CSVs and runs SQL scripts | CSV upload to S3 triggers automatic ingestion |
| No data validation -- bad rows silently corrupt reports | 19 automated tests catch issues before they reach dashboards |
| Schema changes require manual DDL in Snowflake | Infrastructure changes are reviewed in code and applied via Terraform |
| Transformation logic lives in someone's head or a shared SQL file | Transformation logic is version-controlled, documented, and testable |
| No audit trail for what changed and when | Git history tracks every change to models, tests, and infrastructure |

### Who Benefits

- **Data analysts** -- query `dim_bookings` directly instead of writing complex SQL against raw data
- **Business stakeholders** -- get consistent metrics (revenue, price per night, stay categories) that everyone agrees on
- **Data engineers** -- manage infrastructure as code, with CI/CD catching errors before they reach production

---

## Architecture

```
  +-------------------+
  |   CSV Files        |    Source data: booking records in DD/MM/YY format
  |   (S3 Bucket)      |    Uploaded manually or by an upstream system
  +---------+---------+
            |
            | S3 Event Notification
            v
  +---------+---------+
  |   AWS SQS Queue    |    Managed automatically by Snowflake
  +---------+---------+
            |
            | Message triggers Snowpipe
            v
  +---------+-------------------+
  |   Snowpipe                   |    Auto-ingest: COPY INTO with ON_ERROR=CONTINUE
  |   (AIRBNB_BOOKING_PIPE_DEV) |    Runs within seconds of file arrival
  +---------+-------------------+
            |
            | Raw data lands here (all VARCHAR columns)
            v
  +---------+-------------------+      +---------------------------+
  |   BOOKING_RAW                |      |  Terraform manages this    |
  |   Schema: RAW                |      |  entire layer:             |
  |   (10 VARCHAR columns)       | <--- |  - Database                |
  |   Immutable landing zone     |      |  - Schema, Table, Pipe     |
  +-----+---------+-------------+      |  - Stage, Format, Integ.   |
        |                               +---------------------------+
        | dbt run
        v
  +-----+---------+-------------+
  |   stg_bookings               |    STAGING layer (View)
  |   Schema: RAW_STAGING        |    - Trims whitespace
  |                               |    - Casts VARCHAR to DATE, DECIMAL
  |                               |    - Calculates nights_booked
  |                               |    - Flags invalid records
  +-----+---------+-------------+
        |
        | dbt run
        v
  +-----+---------+-------------+
  |   dim_bookings               |    ANALYTICS layer (Table)
  |   Schema: RAW_ANALYTICS      |    - Surrogate keys
  |                               |    - Price per night, revenue
  |                               |    - Stay categories, lead time
  |   30+ columns of enriched     |    - Time dimensions
  |   analytics-ready data        |    - Status flags and display labels
  +-----+---------+-------------+
        |
        | SELECT queries
        v
  +-----+---------+-------------+
  |   BI Tools / Reports          |    Tableau, Power BI, Looker, etc.
  |   (Optional downstream)       |    Connect directly to RAW_ANALYTICS
  +-------------------------------+
```

### Three Schemas, Three Purposes

| Schema | Purpose | Who Writes | Who Reads |
|--------|---------|------------|-----------|
| `RAW` | Landing zone for unmodified CSV data | Snowpipe (automatic) | dbt staging models |
| `RAW_STAGING` | Cleaned, typed, validated data | dbt (`stg_bookings` view) | dbt mart models |
| `RAW_ANALYTICS` | Enriched, business-ready data | dbt (`dim_bookings` table) | Analysts, BI tools, dashboards |

---

## Technology Stack

### Core Components

| Technology | Role in This Project | Why This Tool |
|------------|----------------------|---------------|
| **Snowflake** | Cloud data warehouse | Separates storage from compute, native S3 integration, Snowpipe for streaming ingestion, scales on demand |
| **Terraform** | Infrastructure as Code | Defines all 7 Snowflake resources in version-controlled `.tf` files. Changes are reviewed before applying, and infrastructure can be recreated from scratch |
| **dbt** | Data transformation | SQL-based transformations with built-in testing, documentation, and dependency management. Models are version-controlled and CI/CD compatible |
| **AWS S3** | File storage (data source) | Industry-standard object storage. CSV files are dropped here by upstream systems or manual upload |
| **Snowpipe** | Automated ingestion | Snowflake-native service that detects new S3 files via SQS notifications and loads them automatically, typically within 30--120 seconds |
| **GitHub Actions** | CI/CD automation | Validates Terraform code on every push, compiles dbt models, and deploys transformations to Snowflake with an approval gate |

### Supporting Libraries

| Library | Version | Purpose |
|---------|---------|---------|
| `dbt-snowflake` | 1.11.1 | Snowflake adapter for dbt |
| `dbt_utils` | >= 1.0.0 | Surrogate key generation (`generate_surrogate_key`) and expression-based tests |
| `dbt_expectations` | >= 0.10.0 | Extended data quality test library |
| Snowflake Terraform Provider | ~> 0.87 | Terraform provider for managing Snowflake resources |

### Authentication

All connections to Snowflake (Terraform, dbt, CI/CD) use **RSA key-pair authentication** (JWT). No passwords are stored or transmitted anywhere. The private key is encrypted with a passphrase.

---

## End-to-End Data Flow: Step by Step

Here is exactly what happens when a new CSV file is uploaded, from start to finish.

### Step 1: File Arrives in S3

A CSV file is uploaded to the `Booking/` folder in the S3 bucket. The file has 10 columns, a header row, and uses DD/MM/YY date format:

```
booking_id,listing_id,host_id,guest_id,check_in_date,check_out_date,total_price,currency,booking_status,created_at
BK001,LST001,HOST001,GUEST001,15/03/24,18/03/24,450,USD,confirmed,01/03/24
```

### Step 2: S3 Notifies Snowpipe

S3 has an event notification configured on the `Booking/` prefix. When a new file is created, S3 sends a message to an SQS queue that Snowflake manages. This happens within seconds.

### Step 3: Snowpipe Loads the Data

Snowpipe picks up the SQS message and runs a `COPY INTO` command to load the CSV rows into the `BOOKING_RAW` table. All data is stored as `VARCHAR` (text) at this stage -- no type conversion happens during ingestion. This is intentional: it prevents load failures from bad data.

The pipe is configured with `ON_ERROR = 'CONTINUE'`, meaning a malformed row will be skipped rather than failing the entire file.

**Result:** Raw data is in `AIRBNB_PROJECT_DEV.RAW.BOOKING_RAW` within 1--2 minutes.

### Step 4: dbt Transforms the Data (Triggered Separately)

Running `dbt run` (locally or via CI/CD) processes two models in order:

**Model 1: `stg_bookings` (staging view)**

Reads from `BOOKING_RAW` and:
- Trims whitespace from all text fields
- Converts date strings (`15/03/24`) to proper `DATE` type using `try_to_date()`
- Converts price strings to `DECIMAL(12,2)` using `try_to_decimal()`
- Calculates `nights_booked` as the difference between check-out and check-in
- Normalizes status values to lowercase
- Flags records that fail basic validation (missing IDs, invalid dates, negative prices) with `_is_invalid_record = true`
- Filters out rows with null booking IDs

**Model 2: `dim_bookings` (analytics table)**

Reads from `stg_bookings` (excluding invalid records) and adds:
- **Surrogate key** (`booking_key`) -- an MD5 hash of booking_id for warehouse-style joins
- **Price per night** -- `total_price / nights_booked`
- **Realized revenue** -- total price for confirmed/completed bookings, 0 for cancelled/pending
- **Stay category** -- Weekend (1--2 nights), Week (3--7), Monthly (8--30), Long-term (31+)
- **Lead time** -- days between booking creation and check-in, with categories (Same Day, Last Minute, Advance, etc.)
- **Time dimensions** -- check-in week, month, quarter, year, day of week, weekend flag
- **Status flags** -- boolean columns (`is_confirmed`, `is_cancelled`, `is_successful`, etc.) and display labels

**Result:** `AIRBNB_PROJECT_DEV.RAW_ANALYTICS.DIM_BOOKINGS` is a fully enriched table ready for queries.

### Step 5: Tests Validate the Output

Running `dbt test` executes 19 checks across both layers:

| Test Category | Examples | Severity |
|---------------|----------|----------|
| **Source tests** (raw data) | BOOKING_ID is not null, BOOKING_ID is unique, BOOKING_STATUS contains only valid values | Warn (won't block CI) |
| **Mart tests** (analytics data) | booking_key is unique and not null, nights_booked is non-negative, check-out is after check-in | Error (blocks CI) |

Source tests use `severity: warn` because raw data quality issues should be flagged but not prevent downstream processing. Mart tests use `severity: error` because the analytics table must be trustworthy.

### Step 6: CI/CD Automates Steps 4--5

When a developer pushes changes to dbt models on the `main` branch, GitHub Actions automatically:
1. Compiles the models to verify SQL syntax (the "Check" job)
2. If compilation passes, deploys models to Snowflake and runs all tests (the "Deploy" job, gated by an optional approval)

---

## What the Analytics Table Contains

The `dim_bookings` table has 30+ columns organized into categories:

### Identifiers

| Column | Description |
|--------|-------------|
| `booking_key` | Surrogate key (MD5 hash) for warehouse-style joins |
| `booking_id` | Original booking ID from the source system |
| `listing_id` | Property that was booked |
| `host_id` | Property owner |
| `guest_id` | Person who made the booking |

### Dates and Duration

| Column | Description |
|--------|-------------|
| `check_in_date` | Guest arrival date |
| `check_out_date` | Guest departure date |
| `created_at` | When the booking was made |
| `nights_booked` | Number of nights (checkout minus check-in) |

### Financial

| Column | Description |
|--------|-------------|
| `total_price` | Total booking amount |
| `currency` | Currency code (e.g., USD) |
| `price_per_night` | Calculated: total_price / nights_booked |
| `realized_revenue` | Revenue counted only for confirmed or completed bookings |

### Booking Status

| Column | Description |
|--------|-------------|
| `booking_status` | Lowercase status: confirmed, pending, cancelled, completed |
| `booking_status_display` | Display label: "Confirmed", "Pending Confirmation", etc. |
| `is_confirmed`, `is_pending`, `is_cancelled`, `is_completed` | Boolean flags for easy filtering |
| `is_successful` | True if confirmed or completed |

### Business Categories

| Column | Description |
|--------|-------------|
| `stay_category` | Weekend / Week / Monthly / Long-term (based on nights) |
| `stay_category_order` | Sort order for the above (1--4) |
| `lead_time_days` | Days between booking creation and check-in |
| `lead_time_category` | Same Day / Last Minute / Short Notice / Advance / Far Advance |

### Time Dimensions

| Column | Description |
|--------|-------------|
| `check_in_week`, `check_in_month`, `check_in_quarter` | Truncated dates for aggregation |
| `check_in_year`, `check_in_month_num` | Numeric year and month |
| `check_in_day_of_week`, `check_in_day_name` | Day as number (0=Sun) and name (Mon, Tue, ...) |
| `is_weekend_checkin` | True if check-in is on Saturday or Sunday |

### Metadata

| Column | Description |
|--------|-------------|
| `_dbt_updated_at` | Timestamp of when dbt last built this row |
| `_model_version` | Model version for tracking schema evolution |

---

## CI/CD Pipelines

Two GitHub Actions workflows automate validation and deployment.

### Terraform Pipeline

**Triggers:** Push or PR to `main` that changes any file in `terraform/`

```
Push to main (terraform/ changed)
        |
        v
  terraform init --> terraform fmt -check --> terraform validate
                                                      |
                                                      v
                                              Validates syntax and
                                              formatting only.
                                              Does NOT apply changes.
```

Terraform `apply` is run manually from a developer's machine because the state file is stored locally. This pipeline catches formatting and syntax errors before they become problems.

### dbt Pipeline

**Triggers:** Push or PR to `main` that changes `dbt/models/`, `dbt_project.yml`, or `packages.yml`. Can also be triggered manually.

```
Push to main (dbt/ changed)
        |
        v
  +------------------+     +--------------------+
  |   dbt Check       |     |   dbt Deploy        |
  |   (every push)    | --> |   (main branch only) |
  +------------------+     +--------------------+
  | - dbt compile     |     | - dbt run            |
  | - Verifies SQL    |     | - dbt test           |
  |   syntax is valid |     | - Deploys to         |
  +------------------+     |   Snowflake           |
                            | - Requires approval   |
                            |   (production env)    |
                            +--------------------+
```

The Deploy job only runs on the `main` branch (not PRs) and is gated by a GitHub Environment called `production`, which can require manual approval.

---

## Project Structure

```
Snow_project_v1/
|
|-- terraform/                      INFRASTRUCTURE LAYER
|   |-- main.tf                     7 Snowflake resources defined here
|   |-- variables.tf                Variable definitions with types and defaults
|   |-- outputs.tf                  Shows resource names + next-step instructions after apply
|   |-- terraform.tfvars.example    Template for configuration values
|   |-- trust-policy.json           AWS IAM trust policy reference
|
|-- dbt/                            TRANSFORMATION LAYER
|   |-- dbt_project.yml             Project config (materialization strategies)
|   |-- packages.yml                External packages (dbt_utils, dbt_expectations)
|   |-- profiles.yml.example        Template for Snowflake connection
|   |-- models/
|       |-- staging/
|       |   |-- sources.yml         Declares raw source + column-level tests
|       |   |-- stg_bookings.sql    Cleans and casts raw data
|       |-- marts/
|           |-- dim_bookings.sql    Enriches data with business logic
|           |-- schema.yml          Mart-level tests and documentation
|
|-- .github/workflows/              AUTOMATION LAYER
|   |-- terraform.yml               Validates Terraform on push
|   |-- dbt.yml                     Compiles, deploys, and tests dbt models
|
|-- snowflake_key/                  AUTHENTICATION (not in Git)
|   |-- rsa_key.p8                  Encrypted private key
|   |-- rsa_key.pub                 Public key (registered in Snowflake)
|
|-- test_data/                      SAMPLE DATA
|   |-- test_booking_1.csv          Sample CSV files for testing the pipeline
|
|-- SETUP_GUIDE.md                  Step-by-step setup instructions
|-- PERMISSIONS.md                  Required access levels by system
|-- PROJECT_OVERVIEW.md             This document
|-- .gitignore                      Prevents secrets and state files from being committed
```

---

## Assumptions

| # | Assumption | Impact If Wrong |
|---|------------|-----------------|
| 1 | CSV files use **DD/MM/YY** date format (e.g., `15/03/24` for March 15, 2024) | Dates will parse as NULL. The staging model uses `try_to_date()` so it won't fail, but records will be flagged as invalid and excluded from `dim_bookings` |
| 2 | CSV files have a **header row** with the exact column names listed in the CSV Format section | Snowpipe will load header text as data row or load columns in wrong order. The file format skips 1 header row |
| 3 | CSV column order matches the table column order exactly (10 columns in the documented sequence) | Data will land in wrong columns. Snowflake's COPY INTO maps by **position**, not by column name |
| 4 | Each `booking_id` is unique across all CSV files | Duplicate IDs will fail the `unique` test on `dim_bookings` and produce duplicate rows in the analytics table |
| 5 | The S3 bucket and Snowflake account are in the **same AWS region** (or close to it) | No functional impact, but cross-region data transfer adds latency and cost |
| 6 | A single Snowflake warehouse (`COMPUTE_WH`) is used for all operations | At scale, you may want separate warehouses for ingestion, transformation, and BI queries to isolate workloads |

---

## Dependencies

| Dependency | Type | Notes |
|------------|------|-------|
| Snowflake account | External service | Must be active with ACCOUNTADMIN access for initial setup |
| AWS account | External service | S3 bucket and IAM role must be in place before Terraform runs |
| GitHub repository | External service | Hosts code and runs CI/CD workflows |
| Snowflake Terraform Provider v0.87.x | Software | Pinned in `main.tf`. Newer versions may change resource behavior |
| dbt-snowflake v1.11.1 | Software | Pinned in CI/CD. Major version changes may break model syntax |
| `dbt_utils` >= 1.0.0 | dbt package | Used for surrogate key generation and expression tests |
| `dbt_expectations` >= 0.10.0 | dbt package | Available for advanced data quality testing (not heavily used yet) |
| RSA key-pair | Local file | Must exist before running Terraform or dbt. The public key must be registered in Snowflake |

---

## Common Failure Points and How They Are Handled

### 1. Malformed CSV Rows

**What can go wrong:** A CSV file contains a row with the wrong number of columns, unescaped commas, or completely invalid data.

**How it is handled:**
- Snowpipe's `ON_ERROR = 'CONTINUE'` skips bad rows instead of failing the entire file load
- The file format sets `empty_field_as_null = true` and `null_if = ["NULL", "null", ""]` to normalize empty values
- The staging model uses `try_to_date()` and `try_to_decimal()` which return NULL instead of throwing errors on unparseable values
- Records that fail basic validation are flagged with `_is_invalid_record = true` and excluded from the analytics table

**Net effect:** Bad data never reaches `dim_bookings`. It is either skipped at ingestion, nullified during staging, or filtered during mart creation.

### 2. Duplicate File Uploads

**What can go wrong:** The same CSV file is uploaded to S3 twice.

**How it is handled:**
- Snowpipe tracks which files it has already processed. Re-uploading a file with the **same name** to the same path will not re-ingest it
- If duplicate data does get through (e.g., different filename, same content), the `unique` test on `booking_id` in `dim_bookings` will catch it during `dbt test`

**Action needed:** If you must re-process a file, upload it with a different filename or run `ALTER PIPE ... REFRESH`.

### 3. Schema Changes (New or Renamed Columns)

**What can go wrong:** The CSV format changes -- a column is added, removed, or renamed.

**How it is handled:**
- This is **not handled automatically**. Snowflake COPY INTO maps columns by **position**, so any column change requires updates across the full stack:
  1. `terraform/main.tf` -- update the table column definitions
  2. `dbt/models/staging/sources.yml` -- update the source column list
  3. `dbt/models/staging/stg_bookings.sql` -- update the select and cast logic
  4. `dbt/models/marts/dim_bookings.sql` -- update enrichment logic
  5. Drop and recreate the table and pipe in Snowflake, then re-apply Terraform

**This is the most disruptive change** the pipeline can face and should be planned carefully.

### 4. Snowflake Authentication Failure

**What can go wrong:** Terraform or dbt cannot connect to Snowflake. Common causes: expired key, wrong passphrase, public key not registered.

**How it is handled:**
- The RSA key-pair does not expire unless you set a rotation policy
- `dbt debug` is the diagnostic tool -- it tests every component of the connection and reports exactly what failed
- If the key is compromised, generate a new pair, register the new public key with `ALTER USER ... SET RSA_PUBLIC_KEY_2`, rotate the private key in all configs, then unset the old key

### 5. AWS Trust Policy Mismatch

**What can go wrong:** Snowflake cannot read from S3. The IAM role's trust policy does not match Snowflake's IAM user ARN or external ID.

**How it is handled:**
- `SELECT SYSTEM$PIPE_STATUS(...)` in Snowflake will show error details
- `DESCRIBE INTEGRATION ...` provides the correct ARN and external ID values
- The fix is updating the trust policy JSON in AWS IAM with the correct values

**This breaks silently** -- Snowpipe will simply not load new files. Monitor `COPY_HISTORY` regularly.

### 6. CI/CD Pipeline Failures

**What can go wrong:** The GitHub Actions workflow fails.

**How it is handled:**
- **Terraform pipeline:** Only validates; does not apply. A failure here means the code has formatting or syntax errors. Fix and push again.
- **dbt Check job:** Compilation failure means the SQL has syntax errors. Fix the model and push.
- **dbt Deploy job:** If `dbt run` succeeds but `dbt test` fails, the models are already deployed but data quality is compromised. Investigate the test failure, fix the data or model, and re-run.

**The Deploy job requires the Check job to pass first**, so syntax errors never reach Snowflake.

---

## Related Documents

| Document | What It Covers |
|----------|---------------|
| [SETUP_GUIDE.md](SETUP_GUIDE.md) | Step-by-step instructions for setting up the project from scratch (14 steps across 7 phases) |
| [PERMISSIONS.md](PERMISSIONS.md) | Minimum access levels required for each system (Snowflake, AWS, GitHub) |
