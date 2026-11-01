# Lists the changes in a `tofu show -json` plan that need a label, and the checks that block any
# plan. Deletions and weakened protection need allow-resource-deletion; database host changes and
# PostgreSQL major upgrades need allow-downtime and a planned downtime in progress for their service.
def managed: .resource_changes[]? | select(.mode == "managed");
def weakened:
  (.before.deletion_protection == true and .after.deletion_protection != true)
  or (.before.force_destroy == false and .after.force_destroy == true)
  or ((.before.deletion_policy // "DELETE") != "DELETE" and .after.deletion_policy == "DELETE");
# Instance templates are immutable configuration, terraform_data holds only a run token, and a
# finished Job only records its run, so replacing any of them deletes nothing that holds data.
def harmless_replacement:
  (.type == "google_compute_instance_template" or .type == "terraform_data" or .type == "kubernetes_job_v1") and (.change.actions | index("create"));
# A database host restarts onto a new template or group configuration once rolled out. Creating or
# retiring a host restarts nothing, and neither does lifting its deletion protection.
def database_host_change:
  (.type == "google_compute_instance_template" or .type == "google_compute_instance_group_manager")
  and .name == "database" and (.change.actions | index("create") and index("delete") or . == ["update"])
  and (.change.before | del(.deletion_policy)) != (.change.after | del(.deletion_policy));
# CloudNativePG upgrades a database's PostgreSQL major in place, with every instance stopped until
# pg_upgrade ends. Any other change to a database rolls by switchover.
def major_upgrade:
  .type == "kubernetes_manifest" and .name == "database" and .change.actions == ["update"]
  and .change.before.manifest.spec.imageCatalogRef.major != .change.after.manifest.spec.imageCatalogRef.major;
{
  deletions: [managed | select((.change.actions | index("delete") or index("forget")) and (harmless_replacement | not)) | .address],
  weakened: [managed | select(.change.actions == ["update"] and (.change | weakened)) | .address],
  # Foundation keys its hosts by identity (json_keys); downtimes name the service root (json-keys).
  downtime_changes: [managed | select(database_host_change or major_upgrade) | {address, service: (.index | gsub("_"; "-"))}],
  major_upgrades: [managed | select(major_upgrade) | .index],
  failed_checks: [.checks[]? | select(.status == "fail" or .status == "error") | .address.to_display]
}
