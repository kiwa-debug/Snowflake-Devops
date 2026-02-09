# ─────────────────────────────────────────────
# Variable Definitions
# ─────────────────────────────────────────────

# ── Environment ──────────────────────────────

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "airbnb"
}

# ── Snowflake Connection (Key-Pair Auth) ─────

variable "snowflake_organization_name" {
  description = "Snowflake organization name (first part of account identifier, e.g., WYOJMCE)"
  type        = string
}

variable "snowflake_account_name" {
  description = "Snowflake account name (second part of account identifier, e.g., SV40906)"
  type        = string
}

variable "snowflake_user" {
  description = "Snowflake username for Terraform"
  type        = string
}

variable "snowflake_role" {
  description = "Snowflake role to use"
  type        = string
  default     = "ACCOUNTADMIN"
}

variable "snowflake_warehouse" {
  description = "Snowflake warehouse to use"
  type        = string
  default     = "COMPUTE_WH"
}

variable "snowflake_private_key_path" {
  description = "Path to RSA private key file (.p8) relative to terraform/"
  type        = string
}

variable "snowflake_private_key_passphrase" {
  description = "Passphrase for the encrypted RSA private key"
  type        = string
  sensitive   = true
}

# ── Database ─────────────────────────────────

variable "database_name" {
  description = "Base name for the Snowflake database (environment suffix added automatically)"
  type        = string
  default     = "AIRBNB_PROJECT"
}

variable "raw_schema_name" {
  description = "Name of the raw data schema"
  type        = string
  default     = "RAW"
}

# ── AWS S3 ───────────────────────────────────

variable "s3_bucket_name" {
  description = "Name of the S3 bucket containing source data"
  type        = string
}

variable "s3_bucket_path" {
  description = "Path prefix within the S3 bucket (e.g., Booking/)"
  type        = string
  default     = "Booking/"
}

variable "s3_bucket_url" {
  description = "Full S3 URL to the data folder (e.g., s3://bucket/path/)"
  type        = string
}

variable "aws_role_arn" {
  description = "ARN of the AWS IAM role for Snowflake S3 access"
  type        = string
}

# ── Snowpipe ─────────────────────────────────

variable "auto_ingest_enabled" {
  description = "Enable auto-ingest for Snowpipe (requires S3 event notification)"
  type        = bool
  default     = true
}

variable "file_format_type" {
  description = "File format type (CSV, JSON, PARQUET, etc.)"
  type        = string
  default     = "CSV"
}

variable "csv_skip_header" {
  description = "Number of header rows to skip in CSV files"
  type        = number
  default     = 1
}

variable "csv_field_delimiter" {
  description = "Field delimiter for CSV files"
  type        = string
  default     = ","
}

# ── Tags ─────────────────────────────────────

variable "tags" {
  description = "Resource tags for cost tracking and organization"
  type        = map(string)
  default = {
    project     = "airbnb-data-pipeline"
    managed_by  = "terraform"
    cost_center = "data-engineering"
  }
}
