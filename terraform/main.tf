# ─────────────────────────────────────────────
# Terraform Configuration & Provider
# ─────────────────────────────────────────────

terraform {
  required_version = ">= 1.0"

  required_providers {
    snowflake = {
      source  = "Snowflake-Labs/snowflake"
      version = "~> 0.87"
    }
  }
}

provider "snowflake" {
  organization_name      = var.snowflake_organization_name
  account_name           = var.snowflake_account_name
  user                   = var.snowflake_user
  role                   = var.snowflake_role
  warehouse              = var.snowflake_warehouse
  authenticator          = "SNOWFLAKE_JWT"
  private_key            = file(var.snowflake_private_key_path)
  private_key_passphrase = var.snowflake_private_key_passphrase
}

# ─────────────────────────────────────────────
# Local Variables
# ─────────────────────────────────────────────

locals {
  env_suffix    = upper(var.environment)
  db_name       = "${upper(var.database_name)}_${local.env_suffix}"
  schema_name   = upper(var.raw_schema_name)
  pipe_name     = "AIRBNB_BOOKING_PIPE_${local.env_suffix}"
  stage_name    = "AIRBNB_S3_STAGE_${local.env_suffix}"
  int_name      = "AIRBNB_S3_INT_${local.env_suffix}"
  format_name   = "AIRBNB_CSV_FORMAT_${local.env_suffix}"
  table_name    = "BOOKING_RAW"
}

# ─────────────────────────────────────────────
# 1. Database
# ─────────────────────────────────────────────

resource "snowflake_database" "this" {
  name    = local.db_name
  comment = "Airbnb data pipeline database (${var.environment}) — managed by Terraform"
}

# ─────────────────────────────────────────────
# 2. Schema
# ─────────────────────────────────────────────

resource "snowflake_schema" "raw" {
  database = snowflake_database.this.name
  name     = local.schema_name
  comment  = "Raw ingestion schema — managed by Terraform"
}

# ─────────────────────────────────────────────
# 3. Storage Integration (S3)
# ─────────────────────────────────────────────

resource "snowflake_storage_integration" "s3" {
  name    = local.int_name
  type    = "EXTERNAL_STAGE"
  enabled = true

  storage_provider         = "S3"
  storage_allowed_locations = ["s3://${var.s3_bucket_name}/${var.s3_bucket_path}"]
  storage_aws_role_arn     = var.aws_role_arn

  comment = "S3 integration for ${var.s3_bucket_name} — managed by Terraform"
}

# ─────────────────────────────────────────────
# 4. File Format (CSV)
# ─────────────────────────────────────────────

resource "snowflake_file_format" "csv" {
  name        = local.format_name
  database    = snowflake_database.this.name
  schema      = snowflake_schema.raw.name
  format_type = var.file_format_type

  skip_header      = var.csv_skip_header
  field_delimiter   = var.csv_field_delimiter
  field_optionally_enclosed_by = "\""
  empty_field_as_null          = true
  null_if                      = ["NULL", "null", ""]

  comment = "CSV file format for booking data — managed by Terraform"
}

# ─────────────────────────────────────────────
# 5. External Stage
# ─────────────────────────────────────────────

resource "snowflake_stage" "s3" {
  name        = local.stage_name
  database    = snowflake_database.this.name
  schema      = snowflake_schema.raw.name
  url         = var.s3_bucket_url

  storage_integration = snowflake_storage_integration.s3.name
  file_format         = "FORMAT_NAME = ${snowflake_database.this.name}.${snowflake_schema.raw.name}.${snowflake_file_format.csv.name}"

  comment = "S3 external stage for booking data — managed by Terraform"
}

# ─────────────────────────────────────────────
# 6. Raw Table (All VARCHAR to avoid collation bug)
# ─────────────────────────────────────────────

resource "snowflake_table" "booking_raw" {
  database = snowflake_database.this.name
  schema   = snowflake_schema.raw.name
  name     = local.table_name
  comment  = "Raw booking data ingested by Snowpipe — managed by Terraform"

  column {
    name = "BOOKING_ID"
    type = "VARCHAR"
  }

  column {
    name = "LISTING_ID"
    type = "VARCHAR"
  }

  column {
    name = "HOST_ID"
    type = "VARCHAR"
  }

  column {
    name = "GUEST_ID"
    type = "VARCHAR"
  }

  column {
    name = "CHECK_IN_DATE"
    type = "VARCHAR"
  }

  column {
    name = "CHECK_OUT_DATE"
    type = "VARCHAR"
  }

  column {
    name = "TOTAL_PRICE"
    type = "VARCHAR"
  }

  column {
    name = "CURRENCY"
    type = "VARCHAR"
  }

  column {
    name = "BOOKING_STATUS"
    type = "VARCHAR"
  }

  column {
    name = "CREATED_AT"
    type = "VARCHAR"
  }
}

# ─────────────────────────────────────────────
# 7. Snowpipe (Auto-ingest from S3)
# ─────────────────────────────────────────────

resource "snowflake_pipe" "booking" {
  name     = local.pipe_name
  database = snowflake_database.this.name
  schema   = snowflake_schema.raw.name

  auto_ingest = var.auto_ingest_enabled

  copy_statement = <<-SQL
    COPY INTO ${snowflake_database.this.name}.${snowflake_schema.raw.name}.${snowflake_table.booking_raw.name}
    FROM @${snowflake_database.this.name}.${snowflake_schema.raw.name}.${snowflake_stage.s3.name}
    FILE_FORMAT = (FORMAT_NAME = '${snowflake_database.this.name}.${snowflake_schema.raw.name}.${snowflake_file_format.csv.name}')
    ON_ERROR = 'CONTINUE'
  SQL

  comment = "Snowpipe for auto-ingesting booking CSVs from S3 — managed by Terraform"
}
