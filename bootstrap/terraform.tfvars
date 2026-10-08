management_project_id = "a-novel-management-prod"
region                = "europe-west1"
storage_location      = "EU"
operator_principals = [
  "user:geoffroy.vincent@agorastoryverse.com",
]
native_backups = {
  json-keys = {
    workload_project_id = "a-novel-production-prod"
    zone                = "private"
    tls_credentials     = true
    noncurrent_cleanup  = false
  }
  authentication = {
    workload_project_id = "a-novel-production-prod"
    zone                = "private"
    tls_credentials     = true
    noncurrent_cleanup  = false
  }
}
