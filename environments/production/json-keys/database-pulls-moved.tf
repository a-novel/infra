# The database host's pull grants moved from the backups module to service-runtime, which owns the
# repositories, so a host without native backups pulls too.
moved {
  from = module.backups.google_artifact_registry_repository_iam_member.readers["production/database"]
  to   = module.runtime.google_artifact_registry_repository_iam_member.database["production"]
}

moved {
  from = module.backups.google_artifact_registry_repository_iam_member.readers["tooling/database"]
  to   = module.runtime.google_artifact_registry_repository_iam_member.database["tooling"]
}
