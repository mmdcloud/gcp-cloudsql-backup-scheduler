
# -------------------------------------------------------------------------------
# Getting Project Information
# -------------------------------------------------------------------------------
data "google_project" "project" {}

# -------------------------------------------------------------------------------
# Registering Vault Provider
# -------------------------------------------------------------------------------
data "vault_generic_secret" "sql" {
  path = "secret/sql"
}

# -------------------------------------------------------------------------------
# VPC Configuration
# -------------------------------------------------------------------------------
module "vpc" {
  source                          = "./modules/vpc"
  vpc_name                        = "vpc"
  delete_default_routes_on_create = false
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  subnets                         = []
  firewall_data                   = []
}

# Serverless VPC Creation
module "vpc_connectors" {
  source   = "./modules/network/vpc-connector"
  vpc_name = module.vpc.vpc_name
  serverless_vpc_connectors = [
    {
      name          = "vpc-connector"
      ip_cidr_range = "10.8.0.0/28"
      min_instances = 2
      max_instances = 5
      machine_type  = "f1-micro"
    }
  ]
}

# -------------------------------------------------------------------------------
# Secrets Manager Configuration
# -------------------------------------------------------------------------------
module "sql_password_secret" {
  source      = "./modules/secret-manager"
  secret_data = tostring(data.vault_generic_secret.sql.data["password"])
  secret_id   = "db_password_secret"
}

# -------------------------------------------------------------------------------
# Cloud SQL Configuration
# -------------------------------------------------------------------------------

module "db" {
  source                      = "./modules/cloud-sql"
  name                        = "db-instance"
  db_name                     = "db"
  db_user                     = "mohit"
  db_version                  = "MYSQL_8_0"
  location                    = var.region
  tier                        = "db-f1-micro"
  ipv4_enabled                = false
  availability_type           = "ZONAL"
  disk_size                   = 100
  deletion_protection_enabled = false
  backup_configuration        = []
  vpc_self_link               = module.vpc.self_link
  vpc_id                      = module.vpc.vpc_id
  password                    = module.sql_password_secret.secret_data
  depends_on                  = [module.sql_password_secret]
  database_flags              = []
}

# -------------------------------------------------------------------------------
# Cloud Storage Configuration
# -------------------------------------------------------------------------------

module "backup_function_code" {
  source   = "./modules/gcs"
  location = var.region
  name     = "backup-scheduler-function-code"
  cors     = []
  contents = [
    {
      name        = "backup_function_code.zip"
      source_path = "${path.module}/files/backup_function_code.zip"
      content     = ""
    }
  ]
  force_destroy               = true
  uniform_bucket_level_access = true
}

module "backup_bucket" {
  source   = "./modules/gcs"
  location = var.region
  name     = "bckp-bucket-${data.google_project.project.project_id}"
  cors     = []
  contents = [
    {
      name        = "cloudsql-backups"
      content     = " "
      source_path = ""
    }
  ]
  force_destroy               = true
  uniform_bucket_level_access = true
}

# -------------------------------------------------------------------------------
# Pub/Sub Configuration
# -------------------------------------------------------------------------------
module "pubsub" {
  source                     = "./modules/pubsub"
  name                       = "backup-scheduler-topic"
  message_retention_duration = "86600s"
}

# -------------------------------------------------------------------------------
# Scheduler Configuration
# -------------------------------------------------------------------------------
module "scheduler" {
  source            = "./modules/scheduler"
  name              = "cloudsql-backup-scheduler-job"
  description       = "cloudsql-backup-scheduler-job"
  schedule          = "25 4 * * *"
  pubsub_topic_name = module.pubsub.topic_id
  pubsub_data       = base64encode("Mohit !")
}

# -------------------------------------------------------------------------------
# Backup function
# -------------------------------------------------------------------------------

# Service Account
module "backup_function_app_service_account" {
  source        = "./modules/service-account"
  account_id    = "backup-function-sa"
  display_name  = "backup-function sa"
  project_id    = data.google_project.project.project_id
  member_prefix = "serviceAccount"
  permissions = [
    "roles/iam.serviceAccountUser",
    "roles/run.invoker",
    "roles/eventarc.eventReceiver",
    "roles/cloudsql.client",
    "roles/artifactregistry.reader",
    "roles/secretmanager.admin",
    "roles/pubsub.publisher",
    "roles/cloudsql.admin",
    "roles/storage.admin",
  ]
}

module "backup_function" {
  source                       = "./modules/cloud-run-function"
  function_name                = "backup-function"
  function_description         = "A function to update media details in SQL database after the upload trigger"
  handler                      = "handler"
  runtime                      = "python312"
  location                     = var.region
  storage_source_bucket        = module.backup_function_code.bucket_name
  storage_source_bucket_object = module.backup_function_code.object_name[0].name
  build_env_variables = {
    CLOUD_SQL_INSTANCE_NAME = module.db.db_name
    BUCKET_NAME             = module.backup_bucket.bucket_name
    BACKUP_DIR              = "cloudsql-backups"
    DATABASE_NAME           = module.db.db_name
  }
  all_traffic_on_latest_revision      = true
  vpc_connector                       = module.vpc_connectors.vpc_connectors[0].id
  vpc_connector_egress_settings       = "ALL_TRAFFIC"
  ingress_settings                    = "ALLOW_INTERNAL_ONLY"
  function_app_service_account_email  = module.backup_function_app_service_account.sa_email
  min_instance_count                  = 0
  max_instance_count                  = 3
  available_memory                    = "256M"
  timeout_seconds                     = 60
  event_trigger_event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
  event_trigger_topic                 = module.pubsub.topic_id
  event_trigger_retry_policy          = "RETRY_POLICY_RETRY"
  event_trigger_service_account_email = module.backup_function_app_service_account.sa_email
  event_filters                       = []
  depends_on                          = [module.backup_function_app_service_account]
}