# Required Permissions and Access Levels

This document lists every permission needed to set up and run the Snowflake Data Pipeline project. It follows the **principle of least privilege** -- each entry describes the minimum access required, not more.

Use this as a checklist when requesting access from your security or admin team.

---

## Summary Table

| System | Role / Access Level | Mandatory? | Likely Needs Approval? |
|--------|---------------------|------------|------------------------|
| Snowflake | ACCOUNTADMIN (or custom role -- see below) | Yes | Yes |
| AWS IAM | IAM Administrator (one-time setup) | Yes | Yes |
| AWS S3 | Bucket Owner or s3:PutObject | Yes | Possibly |
| GitHub | Repository Admin | Yes | No (if you own the repo) |
| Local Machine | Standard user (no sudo) | Yes | No |
| BI Tools | Read-only access to Snowflake | Optional | No |

---

## 1. Snowflake Permissions

Snowflake is the core data platform. Two personas need access: the **service account** (used by Terraform, dbt, and CI/CD) and the **human administrator** (who creates the service account).

### 1a. Human Administrator (One-Time Setup)

This person sets up the service account. After setup, they do not need ongoing access.

| Permission | Level | Why It Is Needed |
|------------|-------|------------------|
| `ACCOUNTADMIN` role | Account | Required to run `CREATE USER`, `GRANT ROLE`, and `ALTER USER ... SET RSA_PUBLIC_KEY`. These are account-level operations that only ACCOUNTADMIN (or SECURITYADMIN + USERADMIN) can perform. |

**Approval required?** Yes. Ask your Snowflake account administrator to either grant you temporary ACCOUNTADMIN access or run the setup commands on your behalf.

**Commands that require this access:**

```sql
-- Create the service account
CREATE USER TF_USER
  DEFAULT_ROLE = ACCOUNTADMIN
  DEFAULT_WAREHOUSE = COMPUTE_WH;

-- Grant it a role
GRANT ROLE ACCOUNTADMIN TO USER TF_USER;

-- Register the RSA public key
ALTER USER TF_USER SET RSA_PUBLIC_KEY='...';
```

### 1b. Service Account (TF_USER) -- Terraform

Terraform creates and manages 7 Snowflake resources. The service account needs these privileges:

| Privilege | Scope | Resources It Affects | Why It Is Needed |
|-----------|-------|----------------------|------------------|
| `CREATE DATABASE` | Account | `AIRBNB_PROJECT_DEV` | Terraform creates the project database |
| `CREATE INTEGRATION` | Account | `AIRBNB_S3_INT_DEV` | Terraform creates the S3 storage integration. **This is the privilege that typically requires ACCOUNTADMIN** because storage integrations are account-level objects |
| `USAGE` | Warehouse (`COMPUTE_WH`) | All queries | Every Snowflake operation needs a warehouse to run |
| `CREATE SCHEMA` | Database | `RAW` | Terraform creates the raw data schema inside the database |
| `CREATE TABLE` | Schema (`RAW`) | `BOOKING_RAW` | Terraform creates the raw landing table |
| `CREATE STAGE` | Schema (`RAW`) | `AIRBNB_S3_STAGE_DEV` | Terraform creates the external stage pointing to S3 |
| `CREATE FILE FORMAT` | Schema (`RAW`) | `AIRBNB_CSV_FORMAT_DEV` | Terraform creates the CSV file format definition |
| `CREATE PIPE` | Schema (`RAW`) | `AIRBNB_BOOKING_PIPE_DEV` | Terraform creates the Snowpipe for auto-ingestion |

**Why ACCOUNTADMIN is used today:** The `CREATE INTEGRATION` privilege is only available to ACCOUNTADMIN by default. This is the single reason the project uses ACCOUNTADMIN. All other operations could be done with a lower-privileged custom role.

**Least-privilege alternative (custom role):**

If your organization restricts ACCOUNTADMIN, ask an admin to create a custom role:

```sql
-- Run as ACCOUNTADMIN (one-time)
CREATE ROLE DATA_PIPELINE_ADMIN;

GRANT CREATE DATABASE ON ACCOUNT TO ROLE DATA_PIPELINE_ADMIN;
GRANT CREATE INTEGRATION ON ACCOUNT TO ROLE DATA_PIPELINE_ADMIN;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE DATA_PIPELINE_ADMIN;

GRANT ROLE DATA_PIPELINE_ADMIN TO USER TF_USER;
ALTER USER TF_USER SET DEFAULT_ROLE = DATA_PIPELINE_ADMIN;
```

After Terraform creates the database, grant schema-level privileges:

```sql
GRANT ALL PRIVILEGES ON DATABASE AIRBNB_PROJECT_DEV TO ROLE DATA_PIPELINE_ADMIN;
GRANT ALL PRIVILEGES ON ALL SCHEMAS IN DATABASE AIRBNB_PROJECT_DEV TO ROLE DATA_PIPELINE_ADMIN;
```

### 1c. Service Account (TF_USER) -- dbt

dbt connects as the same service account but needs a different set of privileges. It reads from the raw schema and writes to staging and analytics schemas.

| Privilege | Scope | Why It Is Needed |
|-----------|-------|------------------|
| `USAGE` | Database (`AIRBNB_PROJECT_DEV`) | dbt needs to connect to the database |
| `USAGE` | Warehouse (`COMPUTE_WH`) | dbt needs compute resources to run queries |
| `SELECT` | Table `RAW.BOOKING_RAW` | The staging model reads raw data |
| `CREATE SCHEMA` | Database | dbt auto-creates `RAW_STAGING` and `RAW_ANALYTICS` schemas on first run |
| `CREATE VIEW` | Schema (`RAW_STAGING`) | The `stg_bookings` model is materialized as a view |
| `CREATE TABLE` | Schema (`RAW_ANALYTICS`) | The `dim_bookings` model is materialized as a table |
| `SELECT` | Views/Tables in `RAW_STAGING` | dbt reads staging views to build mart tables |

**Note:** If the service account already has ACCOUNTADMIN or the custom `DATA_PIPELINE_ADMIN` role (from 1b), all of these are implicitly granted. No additional setup is needed.

### 1d. Authentication Method

| Detail | Value |
|--------|-------|
| Method | RSA Key-Pair (JWT) |
| Private key file | `snowflake_key/rsa_key.p8` (encrypted with passphrase) |
| Public key | Registered on the Snowflake user via `ALTER USER ... SET RSA_PUBLIC_KEY` |
| Password | Not used. No password is set or required. |

**Why key-pair instead of password?**
- More secure: the private key never leaves your machine or CI/CD runner
- No password rotation policies to manage
- Industry standard for service accounts

---

## 2. AWS Permissions

AWS provides the S3 storage layer and the IAM trust relationship that lets Snowflake read from S3.

### 2a. IAM Permissions (One-Time Setup)

The person setting up the AWS side needs IAM administrative access to create a role and policies.

| Permission | AWS Service | Why It Is Needed |
|------------|-------------|------------------|
| `iam:CreateRole` | IAM | Create the `snowflake-s3-access-role` that Snowflake will assume |
| `iam:PutRolePolicy` | IAM | Attach the inline S3 read policy to the role |
| `iam:UpdateAssumeRolePolicyDocument` | IAM | Update the role's trust policy with Snowflake's IAM user ARN and external ID (Step 8b in setup guide) |
| `iam:GetRole` | IAM | Verify the role was created correctly |

**Approval required?** Yes. IAM changes are typically restricted to cloud administrators or security teams. Provide them with the exact policy JSON from the setup guide.

**Minimum IAM policy for the setup person:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:GetRole",
        "iam:PutRolePolicy",
        "iam:UpdateAssumeRolePolicyDocument"
      ],
      "Resource": "arn:aws:iam::*:role/snowflake-s3-access-role"
    }
  ]
}
```

### 2b. S3 Bucket Permissions (Snowflake Reads)

The IAM role `snowflake-s3-access-role` needs these permissions on the S3 bucket. Snowflake assumes this role to read CSV files.

| Permission | Why It Is Needed |
|------------|------------------|
| `s3:GetObject` | Read individual CSV files from the `Booking/` prefix |
| `s3:GetObjectVersion` | Read specific file versions (if bucket versioning is enabled) |
| `s3:ListBucket` | List files in the `Booking/` folder to discover new uploads |
| `s3:GetBucketLocation` | Determine the bucket's AWS region for optimal data transfer |

**These are read-only permissions.** Snowflake never writes to or deletes from S3.

**Scoped to a specific bucket and path:**

```json
"Resource": [
  "arn:aws:s3:::YOUR_BUCKET_NAME",
  "arn:aws:s3:::YOUR_BUCKET_NAME/*"
]
```

### 2c. S3 Bucket Permissions (Human User -- Uploading Data)

The person or system that uploads CSV files to S3 needs write access.

| Permission | Why It Is Needed |
|------------|------------------|
| `s3:PutObject` | Upload CSV files to the `Booking/` folder |
| `s3:ListBucket` | Browse the bucket to verify uploads (optional but helpful) |

**Approval required?** Depends on your organization. If the S3 bucket already exists and is managed by another team, you will need their approval.

### 2d. S3 Event Notification Permissions (One-Time Setup)

Configuring the S3-to-Snowpipe event notification requires bucket-level admin access.

| Permission | Why It Is Needed |
|------------|------------------|
| `s3:PutBucketNotification` | Configure the S3 event notification that triggers Snowpipe via SQS |
| `s3:GetBucketNotification` | Verify the notification was configured correctly |

**Approval required?** Yes, if you do not own the S3 bucket. The bucket owner or an S3 administrator needs to set this up. Provide them the SQS ARN from Snowflake.

---

## 3. GitHub Permissions

GitHub hosts the code and runs CI/CD pipelines via GitHub Actions.

### 3a. Repository Access

| Permission | Level | Why It Is Needed |
|------------|-------|------------------|
| Repository Admin | Repository | Required to configure Secrets, Variables, and Environments under repository Settings |
| Push to `main` | Repository | Required to trigger CI/CD workflows on the main branch |
| Pull Request creation | Repository | Required for PR-based workflows (optional if you push directly to main) |

**Approval required?** No, if you created the repository yourself. If the repository belongs to an organization, you may need an org admin to grant you the Admin role on the repository.

### 3b. Personal Access Token (PAT) Scopes

A GitHub Personal Access Token is used to push code from the command line. These are the minimum scopes:

| Scope | Why It Is Needed |
|-------|------------------|
| `repo` | Push code, create branches, read private repository content |
| `workflow` | Push changes to `.github/workflows/` files. **Without this scope, GitHub rejects pushes that modify workflow files.** |

**Note:** `workflow` scope is often overlooked. If you get a "refusing to allow... workflow scope" error, this is the fix.

### 3c. GitHub Secrets (Stored in Repository Settings)

These secrets are injected into CI/CD workflows at runtime. They are never visible in logs.

| Secret Name | Contains | Used By |
|-------------|----------|---------|
| `SNOWFLAKE_ORG_NAME` | Snowflake organization name (e.g., `HHMNKHZ`) | Both workflows |
| `SNOWFLAKE_ACCOUNT_NAME` | Snowflake account name (e.g., `QIC56996`) | Both workflows |
| `SNOWFLAKE_USER` | Service account username (e.g., `TF_USER`) | Both workflows |
| `SNOWFLAKE_PRIVATE_KEY` | Full contents of `rsa_key.p8` (including BEGIN/END lines) | Both workflows |
| `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE` | Passphrase for the private key | Both workflows |
| `AWS_ROLE_ARN` | IAM role ARN (e.g., `arn:aws:iam::123456789012:role/snowflake-s3-access-role`) | Terraform workflow |

**Who can view/edit secrets?** Only repository administrators. Secrets are encrypted and masked in workflow logs.

### 3d. GitHub Variables (Stored in Repository Settings)

Variables are non-sensitive configuration values visible in workflow logs.

| Variable Name | Value | Used By |
|---------------|-------|---------|
| `ENVIRONMENT` | `dev` | Terraform workflow |
| `ENVIRONMENT_UPPER` | `DEV` | dbt workflow |
| `PROJECT_NAME` | `airbnb` | Terraform workflow |
| `DATABASE_NAME` | `AIRBNB_PROJECT` | Both workflows |
| `S3_BUCKET_NAME` | Your bucket name | Terraform workflow |
| `S3_BUCKET_PATH` | `Booking/` | Terraform workflow |
| `S3_BUCKET_URL` | `s3://YOUR_BUCKET/Booking/` | Terraform workflow |

### 3e. GitHub Environments

| Environment | Purpose | Approval Required? |
|-------------|---------|-------------------|
| `production` | Gates dbt deployments that write to Snowflake | Optional (configurable). If reviewers are added, a human must approve each deploy. |

---

## 4. Local Machine Requirements

These are tools installed on the developer's machine. No elevated (root/sudo) permissions are needed.

| Tool | Version | Mandatory? | Why It Is Needed |
|------|---------|------------|------------------|
| Terraform | >= 1.0 | Yes | Provisions Snowflake infrastructure (database, tables, pipes) |
| Python | >= 3.8 | Yes | Required runtime for dbt |
| dbt-snowflake | >= 1.11.1 | Yes | Runs data transformations and tests against Snowflake |
| OpenSSL | Any (pre-installed on macOS/Linux) | Yes | Generates the RSA key-pair for Snowflake authentication |
| Git | Any | Yes | Version control and pushing code to GitHub |
| AWS CLI | v2 | Optional | Upload CSV files to S3 from the command line. You can also upload via the AWS Console web UI instead. |

**Installation (macOS):**

```bash
brew install terraform git awscli
pip install dbt-snowflake
```

---

## 5. BI / Analytics Tool Permissions (Optional)

If you connect a BI tool (Tableau, Power BI, Looker, Metabase, etc.) to the analytics layer, it needs **read-only** access.

| Permission | Scope | Why It Is Needed |
|-----------|-------|------------------|
| `USAGE` | Warehouse `COMPUTE_WH` (or a dedicated BI warehouse) | BI queries need compute resources |
| `USAGE` | Database `AIRBNB_PROJECT_DEV` | Connect to the project database |
| `USAGE` | Schema `RAW_ANALYTICS` | Access the analytics schema |
| `SELECT` | Table `RAW_ANALYTICS.DIM_BOOKINGS` | Read the enriched analytics table |

**Recommended:** Create a separate read-only role for BI users:

```sql
CREATE ROLE BI_READER;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE BI_READER;
GRANT USAGE ON DATABASE AIRBNB_PROJECT_DEV TO ROLE BI_READER;
GRANT USAGE ON SCHEMA AIRBNB_PROJECT_DEV.RAW_ANALYTICS TO ROLE BI_READER;
GRANT SELECT ON ALL TABLES IN SCHEMA AIRBNB_PROJECT_DEV.RAW_ANALYTICS TO ROLE BI_READER;

-- Grant to BI users
GRANT ROLE BI_READER TO USER <bi_username>;
```

---

## Permissions That Need Security / Admin Approval

The following permissions are elevated and will likely require a formal request to your security or cloud administration team.

| # | System | Permission | Who To Ask | What To Tell Them |
|---|--------|------------|------------|-------------------|
| 1 | Snowflake | `ACCOUNTADMIN` role (or `CREATE INTEGRATION` privilege) | Snowflake account admin | "I need to create a storage integration to connect Snowflake to an S3 bucket. This is a one-time setup. Alternatively, grant `CREATE INTEGRATION` to a custom role." |
| 2 | Snowflake | `CREATE USER` and `ALTER USER` | Snowflake SECURITYADMIN or USERADMIN | "I need to create a service account (`TF_USER`) and register an RSA public key for key-pair authentication. No password will be set." |
| 3 | AWS | IAM role creation (`iam:CreateRole`) | AWS IAM administrator | "I need an IAM role named `snowflake-s3-access-role` with read-only S3 access. Snowflake will assume this role using an external ID for cross-account trust." |
| 4 | AWS | IAM trust policy update | AWS IAM administrator | "After the Snowflake integration is created, I need to update the role's trust policy with Snowflake's IAM user ARN and external ID. I will provide the exact JSON." |
| 5 | AWS | S3 event notification | S3 bucket owner | "I need to add an SQS event notification on the `Booking/` prefix so Snowpipe auto-ingests new files. I will provide the SQS ARN." |
| 6 | GitHub | Repository Admin access | GitHub org admin | "I need Admin access to configure repository Secrets, Variables, and Environments for CI/CD pipelines." (Only relevant if the repo is in an organization) |

---

## Permission Lifecycle

Not all permissions are needed forever. Here is when each is required:

| Permission | When Needed | Can Be Revoked After Setup? |
|------------|-------------|-----------------------------|
| Snowflake ACCOUNTADMIN (human) | Initial setup only | Yes -- revoke after creating the service account and storage integration |
| AWS IAM Administrator | Initial setup + trust policy update | Yes -- revoke after trust policy is configured |
| AWS S3 PutBucketNotification | Initial setup only | Yes -- revoke after event notification is configured |
| Snowflake service account (TF_USER) | Ongoing | No -- needed for Terraform, dbt, and CI/CD |
| AWS S3 read (via IAM role) | Ongoing | No -- needed for Snowpipe to ingest files |
| AWS S3 write (human/system uploading CSVs) | Ongoing | No -- needed to feed data into the pipeline |
| GitHub Admin | Ongoing (for secret rotation) | Can be reduced to Write after initial setup, but Admin is needed to update Secrets |

---

## Security Best Practices

1. **Never commit secrets to Git.** The `.gitignore` file excludes `rsa_key.p8`, `rsa_key.pub`, `terraform.tfvars`, and `terraform.tfstate`. Verify with `git status` before pushing.

2. **Use key-pair authentication, not passwords.** The project uses RSA-JWT for all Snowflake connections. No password is stored anywhere.

3. **Rotate keys periodically.** Generate a new key-pair, register the new public key with `ALTER USER TF_USER SET RSA_PUBLIC_KEY_2`, then swap to the new private key. Remove the old key afterward with `ALTER USER TF_USER UNSET RSA_PUBLIC_KEY`.

4. **Scope IAM policies to specific resources.** The S3 policy only grants access to the specific bucket and path, not all S3 buckets.

5. **Use GitHub Secrets for all credentials in CI/CD.** Never hardcode account names, usernames, or keys in workflow files.

6. **Use GitHub Environments with required reviewers.** The `production` environment can be configured to require manual approval before dbt models are deployed to Snowflake.

7. **Prefer custom Snowflake roles over ACCOUNTADMIN.** After initial setup, create a `DATA_PIPELINE_ADMIN` role (see Section 1b) with only the privileges this project needs.
