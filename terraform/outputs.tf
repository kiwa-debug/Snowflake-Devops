# ─────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────

output "database_name" {
  description = "Name of the created Snowflake database"
  value       = snowflake_database.this.name
}

output "schema_name" {
  description = "Name of the raw schema"
  value       = snowflake_schema.raw.name
}

output "table_full_name" {
  description = "Fully qualified name of the raw booking table"
  value       = "${snowflake_database.this.name}.${snowflake_schema.raw.name}.${snowflake_table.booking_raw.name}"
}

output "pipe_full_name" {
  description = "Fully qualified name of the Snowpipe"
  value       = "${snowflake_database.this.name}.${snowflake_schema.raw.name}.${snowflake_pipe.booking.name}"
}

output "storage_integration_name" {
  description = "Name of the S3 storage integration"
  value       = snowflake_storage_integration.s3.name
}

output "stage_full_name" {
  description = "Fully qualified name of the external stage"
  value       = "${snowflake_database.this.name}.${snowflake_schema.raw.name}.${snowflake_stage.s3.name}"
}

# ─────────────────────────────────────────────
# Post-Deploy Instructions
# ─────────────────────────────────────────────

output "next_steps" {
  description = "Steps to complete after terraform apply"
  value       = <<-EOT

    ╔══════════════════════════════════════════════════════════════╗
    ║                   NEXT STEPS (Step 7)                       ║
    ╠══════════════════════════════════════════════════════════════╣
    ║                                                              ║
    ║  1. Run in Snowflake:                                        ║
    ║     DESCRIBE INTEGRATION ${snowflake_storage_integration.s3.name};
    ║                                                              ║
    ║  2. Copy STORAGE_AWS_IAM_USER_ARN and                        ║
    ║     STORAGE_AWS_EXTERNAL_ID from the output.                 ║
    ║                                                              ║
    ║  3. Update AWS IAM Role trust policy with those values.      ║
    ║                                                              ║
    ║  4. Run in Snowflake:                                        ║
    ║     SHOW PIPES IN SCHEMA ${snowflake_database.this.name}.${snowflake_schema.raw.name};
    ║                                                              ║
    ║  5. Copy the notification_channel (SQS ARN).                 ║
    ║                                                              ║
    ║  6. Configure S3 event notification with that SQS ARN.       ║
    ║                                                              ║
    ║  See SETUP_GUIDE.md Step 7 for full details.                 ║
    ╚══════════════════════════════════════════════════════════════╝

  EOT
}
