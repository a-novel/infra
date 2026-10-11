# Lists the changes in a `tofu show -json` plan that need a label, and the checks that block any
# plan. Deletions and weakened protection need allow-resource-deletion; database host changes need
# allow-downtime and a planned downtime in progress for their service.
def managed: .resource_changes[]? | select(.mode == "managed");
def weakened:
  (.before.deletion_protection == true and .after.deletion_protection != true)
  or (.before.force_destroy == false and .after.force_destroy == true)
  or ((.before.deletion_policy // "DELETE") != "DELETE" and .after.deletion_policy == "DELETE");
# Instance templates are immutable configuration, so replacing one deletes nothing that holds data.
def template_replacement:
  .type == "google_compute_instance_template" and (.change.actions | index("create"));
# A database host restarts onto a new template or group configuration once rolled out. Creating a
# new host restarts nothing.
def database_host_change:
  (.type == "google_compute_instance_template" or .type == "google_compute_instance_group_manager")
  and .name == "database" and (.change.actions | index("delete") or . == ["update"]);
{
  deletions: [managed | select((.change.actions | index("delete") or index("forget")) and (template_replacement | not)) | .address],
  weakened: [managed | select(.change.actions == ["update"] and (.change | weakened)) | .address],
  downtime_changes: [managed | select(database_host_change) | {address, service: .index}],
  failed_checks: [.checks[]? | select(.status == "fail" or .status == "error") | .address.to_display]
}
