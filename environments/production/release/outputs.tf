output "region" {
  description = "Configured region used by mocked root tests."
  value       = var.region
}

output "root_name" {
  description = "Stable root identifier used by repository validation."
  value       = local.root_name
}

output "postgres_recovery" {
  description = "Cloud Run jobs and schedules that implement logical PostgreSQL recovery."
  value = {
    backup_jobs = {
      for key, job in google_cloud_run_v2_job.postgres_backup : key => job.name
    }
    restore_jobs = {
      for key, job in google_cloud_run_v2_job.postgres_restore : key => job.name
    }
    monitor_job = try(google_cloud_run_v2_job.postgres_backup_monitor[0].name, null)
    backup_schedules = {
      for key, schedule in google_cloud_scheduler_job.postgres_backup : key => schedule.name
    }
    restore_schedules = {
      for key, schedule in google_cloud_scheduler_job.postgres_restore : key => schedule.name
    }
    monitor_schedule = try(google_cloud_scheduler_job.postgres_backup_monitor[0].name, null)
  }
}
