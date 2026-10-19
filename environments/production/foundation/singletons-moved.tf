# Unconditional singletons keep their objects without the [0] index.
moved {
  from = google_monitoring_notification_channel.cost_email[0]
  to   = google_monitoring_notification_channel.cost_email
}

moved {
  from = google_monitoring_notification_channel.operations_email[0]
  to   = google_monitoring_notification_channel.operations_email
}

moved {
  from = google_billing_budget.workload[0]
  to   = google_billing_budget.workload
}

moved {
  from = google_monitoring_alert_policy.application_jobs_unhealthy[0]
  to   = google_monitoring_alert_policy.application_jobs_unhealthy
}

moved {
  from = google_project_iam_member.plan_viewer[0]
  to   = google_project_iam_member.plan_viewer
}

moved {
  from = google_project_iam_member.scheduler_cloud_run_invoker[0]
  to   = google_project_iam_member.scheduler_cloud_run_invoker
}

moved {
  from = google_project_iam_custom_role.authentication_initializer_deployer[0]
  to   = google_project_iam_custom_role.authentication_initializer_deployer
}
