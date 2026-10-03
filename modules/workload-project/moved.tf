# Keep these relative moves for every existing workload-project caller instance.

moved {
  from = google_project.service
  to   = module.project.google_project.service
}

moved {
  from = google_project_service.api
  to   = module.project.google_project_service.api
}

moved {
  from = google_project_default_service_accounts.service
  to   = module.project.google_project_default_service_accounts.service
}

moved {
  from = google_project_iam_member.foundation
  to   = module.project.google_project_iam_member.foundation
}

moved {
  from = google_project_iam_custom_role.metadata
  to   = module.project.google_project_iam_custom_role.metadata
}

moved {
  from = google_project_iam_member.metadata
  to   = module.project.google_project_iam_member.metadata
}

moved {
  from = google_project_iam_member.plan
  to   = module.project.google_project_iam_member.plan
}

moved {
  from = google_logging_project_bucket_config.default
  to   = module.project.google_logging_project_bucket_config.default
}

moved {
  from = google_project_iam_custom_role.foundation_control_plane
  to   = module.project.google_project_iam_custom_role.foundation_control_plane
}

moved {
  from = google_project_iam_member.foundation_control_plane
  to   = module.project.google_project_iam_member.foundation_control_plane
}

moved {
  from = google_project_iam_custom_role.plan_policy
  to   = module.project.google_project_iam_custom_role.plan_policy
}

moved {
  from = google_project_iam_member.plan_policy
  to   = module.project.google_project_iam_member.plan_policy
}

moved {
  from = google_project_service_identity.agent
  to   = module.project.google_project_service_identity.agent
}

moved {
  from = google_project_iam_member.service_agent
  to   = module.project.google_project_iam_member.service_agent
}

moved {
  from = google_project_iam_member.mig_agent
  to   = module.project.google_project_iam_member.mig_agent
}

moved {
  from = google_service_account.release
  to   = module.release.google_service_account.release
}

moved {
  from = google_iam_workload_identity_pool_provider.release
  to   = module.release.google_iam_workload_identity_pool_provider.release
}

moved {
  from = google_service_account_iam_member.release_federation
  to   = module.release.google_service_account_iam_member.release_federation
}

moved {
  from = google_storage_managed_folder.release
  to   = module.release.google_storage_managed_folder.release
}

moved {
  from = google_storage_managed_folder_iam_member.release
  to   = module.release.google_storage_managed_folder_iam_member.release
}

moved {
  from = google_storage_bucket_iam_member.release_metadata
  to   = module.release.google_storage_bucket_iam_member.release_metadata
}

moved {
  from = google_storage_managed_folder_iam_member.plan
  to   = module.release.google_storage_managed_folder_iam_member.plan
}

moved {
  from = google_storage_bucket_iam_member.plan_operation_reader
  to   = module.release.google_storage_bucket_iam_member.plan_operation_reader
}
