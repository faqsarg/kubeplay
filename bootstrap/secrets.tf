# Postgres credentials — source of truth for ESO.
# Lives in the bootstrap (durable) layer so it survives `destroy` of the cluster.

# 1. generate strong passwords (kept in TF state, which sits encrypted+versioned in S3)
resource "random_password" "postgres" {
  length  = 24
  special = false
}

# the "postgres" superuser needs its own distinct password (bitnami adminPasswordKey)
resource "random_password" "postgres_admin" {
  length  = 24
  special = false
}

# 2. the "box": metadata only, no value yet
resource "aws_secretsmanager_secret" "postgres" {
  name = "kubeplay/staging/postgres"

  tags = {
    Project = "cloud-platform"
  }
}

# 3. the value that goes inside the box (a JSON with the keys ESO will pull)
resource "aws_secretsmanager_secret_version" "postgres" {
  secret_id = aws_secretsmanager_secret.postgres.id
  secret_string = jsonencode({
    username          = "kubeplay"
    password          = random_password.postgres.result       # the "kubeplay" app user
    postgres-password = random_password.postgres_admin.result # the "postgres" superuser
  })
}

# --- Production credentials -------------------------------------------------
# A SEPARATE secret with its OWN passwords: production must be isolated from
# staging even at the credential level (a leaked staging password must not open
# the prod DB). Same shape/keys as staging so the same values.yaml + ESO pattern
# reuse cleanly — only the namespace and the Secrets Manager key differ.
resource "random_password" "postgres_prod" {
  length  = 24
  special = false
}

resource "random_password" "postgres_admin_prod" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "postgres_prod" {
  name = "kubeplay/production/postgres"

  tags = {
    Project = "cloud-platform"
  }
}

resource "aws_secretsmanager_secret_version" "postgres_prod" {
  secret_id = aws_secretsmanager_secret.postgres_prod.id
  secret_string = jsonencode({
    username          = "kubeplay"
    password          = random_password.postgres_prod.result
    postgres-password = random_password.postgres_admin_prod.result
  })
}
