# Lists the changes in a `tofu show -json` plan that need the
# allow-resource-deletion label, and the checks that block any plan.
def managed: .resource_changes[]? | select(.mode == "managed");
def weakened:
  (.before.deletion_protection == true and .after.deletion_protection != true)
  or (.before.force_destroy == false and .after.force_destroy == true)
  or ((.before.deletion_policy // "DELETE") != "DELETE" and .after.deletion_policy == "DELETE");
{
  deletions: [managed | select(.change.actions | index("delete") or index("forget")) | .address],
  weakened: [managed | select(.change.actions == ["update"] and (.change | weakened)) | .address],
  failed_checks: [.checks[]? | select(.status == "fail" or .status == "error") | .address.to_display]
}
