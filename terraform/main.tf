# Getting project information
data "google_project" "project" {}

# Registering vault provider
data "vault_generic_secret" "sql" {
  path = "secret/sql"
}

# VPC Creation
module "vpc" {
  source                  = "./modules/network/vpc"
  auto_create_subnetworks = false
  vpc_name                = "vpc"
  routing_mode            = "REGIONAL"
}

# Subnets Creation
module "public_subnets" {
  source                   = "./modules/network/subnet"
  name                     = "public-subnet"
  subnets                  = var.public_subnets
  vpc_id                   = module.vpc.vpc_id
  private_ip_google_access = false
  location                 = var.region
}

module "private_subnets" {
  source                   = "./modules/network/subnet"
  name                     = "private-subnet"
  subnets                  = var.private_subnets
  vpc_id                   = module.vpc.vpc_id
  private_ip_google_access = true
  location                 = var.region
}

# Firewall Creation
module "firewall" {
  source        = "./modules/network/firewall"
  firewall_data = []
  vpc_id        = module.vpc.vpc_id
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

# Secret Manager
module "sql_password_secret" {
  source      = "./modules/secret-manager"
  secret_data = tostring(data.vault_generic_secret.sql.data["password"])
  secret_id   = "db_password_secret"
}

# Cloud SQL
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
    "roles/pubsub.publisher"
  ]
}

module "backup_function_code" {
  source   = "./modules/gcs"
  location = var.region
  name     = "backup-function-code"
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

# PubSub
module "pubsub" {
  source                     = "./modules/pubsub"
  name                       = "backup-scheduler-topic"
  message_retention_duration = "86600s"
}

# Backup function
module "backup_function" {
  source                              = "./modules/cloud-run-function"
  function_name                       = "backup-function"
  function_description                = "A function to update media details in SQL database after the upload trigger"
  handler                             = "handler"
  runtime                             = "python312"
  location                            = var.region
  storage_source_bucket               = module.backup_function_code.bucket_name
  storage_source_bucket_object        = module.backup_function_code.object_name[0].name
  build_env_variables                 = {}
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