#---------------------------------------------------------------
# Redpanda Enterprise features (TF_VAR_redpanda_enterprise_license, or the built-in
# 30-day trial for the cluster-side ones: redpanda_enterprise_builtin_trial)
#
# The license is stored in Secret redpanda-license (redpanda.tf) and referenced by the
# Redpanda resource (cluster license) and the operator (operator-level license, needed by
# the Connect controller). With it, this stack also enables, unless opted out:
#   - Tiered Storage to a dedicated S3 bucket          redpanda_enterprise_tiered_storage
#   - Continuous Data Balancing                         redpanda_enterprise_continuous_balancing
#   - Redpanda Console login and RBAC                   redpanda_enterprise_console_auth
#   - Redpanda Connect as operator Pipeline resources   redpanda_connect_deployment = auto
# See https://docs.redpanda.com/streaming/current/get-started/licensing/
#---------------------------------------------------------------

#---------------------------------------------------------------
# Tiered Storage: S3 bucket + policy on the broker IAM role (IRSA)
# (cloud_storage_credentials_source = sts; Redpanda uses the web identity token that EKS
# injects for the eks.amazonaws.com/role-arn annotation).
#---------------------------------------------------------------
resource "aws_s3_bucket" "redpanda_tiered_storage" {
  count = local.redpanda_tiered_storage_enabled ? 1 : 0

  bucket_prefix = "${local.name}-tiered-storage-"
  # Topic data is lost with the stack anyway (local NVMe); lets cleanup.sh remove the bucket
  force_destroy = true

  tags = {
    deployment_id = var.deployment_id
  }
}

resource "aws_s3_bucket_public_access_block" "redpanda_tiered_storage" {
  count = local.redpanda_tiered_storage_enabled ? 1 : 0

  bucket = aws_s3_bucket.redpanda_tiered_storage[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "redpanda_tiered_storage" {
  count = local.redpanda_tiered_storage_enabled ? 1 : 0

  bucket = aws_s3_bucket.redpanda_tiered_storage[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_iam_policy" "redpanda_tiered_storage_s3" {
  count = local.redpanda_tiered_storage_enabled ? 1 : 0

  name        = "${local.name}-redpanda-tiered-storage"
  description = "Redpanda brokers read/write their Tiered Storage bucket"

  # Permissions listed in the Redpanda Tiered Storage docs
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.redpanda_tiered_storage[0].arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:PutObjectTagging",
          "s3:DeleteObject",
        ]
        Resource = ["${aws_s3_bucket.redpanda_tiered_storage[0].arn}/*"]
      },
    ]
  })

  tags = {
    deployment_id = var.deployment_id
  }
}

# The policy is attached to the broker IAM role (module.redpanda_broker_irsa in
# redpanda-external-access.tf): one ServiceAccount, one role.

#---------------------------------------------------------------
# Console login: JWT signing key (>= 32 characters) for the session cookies
#---------------------------------------------------------------
resource "random_password" "redpanda_console_jwt" {
  count = local.redpanda_console_auth_enabled ? 1 : 0

  length  = 48
  special = false
}

output "redpanda_enterprise_features" {
  description = "Enterprise features enabled in this deployment"
  value = {
    license              = local.redpanda_license_enabled
    builtin_trial        = !local.redpanda_license_enabled && var.redpanda_enterprise_builtin_trial
    tiered_storage       = local.redpanda_tiered_storage_enabled
    tiered_storage_s3    = try(aws_s3_bucket.redpanda_tiered_storage[0].bucket, null)
    continuous_balancing = local.redpanda_continuous_balancing_enabled
    console_auth         = local.redpanda_console_auth_enabled
    connect              = local.redpanda_connect_mode
  }
}
