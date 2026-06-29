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
