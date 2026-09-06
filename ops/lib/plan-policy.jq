# Known protection fields must stay resolved and at least as strong as before.
# Whole schedules and cleanup rules require policy review because ordering their
# safety from cron expressions or overlapping lifecycle conditions is ambiguous.
def known($path):
  (.after_unknown // {}) as $unknown
  | all(range(0; ($path | length) + 1);
      . as $length | ($unknown | getpath($path[0:$length])) != true) and
    ([($unknown | getpath($path)) | .. | select(. == true)] | length == 0);

def keep($path; $protected):
  if (.before | getpath($path)) == $protected then
    known($path) and (.after | getpath($path)) == $protected
  else true end;

def preserve($path):
  known($path) and (.before | getpath($path)) == (.after | getpath($path));

def minimum($path):
  (.before | getpath($path)) as $before
  | if $before == null then true else
      (.after | getpath($path)) as $after
      | known($path) and
        ($after | type) == "number" and $after >= $before
    end;

def delete_rules:
  [.lifecycle_rule[]? | select(any(.action[]; .type == "Delete"))]
  | sort_by(tojson);

def preserved_disks:
  [.disk[]? | select(.auto_delete == false) | {device_name, source, mode, auto_delete}]
  | sort_by(.device_name);

def protections:
  .type as $type | .change
  | keep(["deletion_protection"]; true) and
    keep(["force_destroy"]; false) and
    keep(["deletion_policy"]; "PREVENT") and
    keep(["deletion_policy"]; "ABANDON") and
    (if $type == "google_storage_bucket" then
      keep(["public_access_prevention"]; "enforced") and
      keep(["uniform_bucket_level_access"]; true) and
      keep(["versioning", 0, "enabled"]; true) and
      keep(["retention_policy", 0, "is_locked"]; true) and
      minimum(["retention_policy", 0, "retention_period"]) and
      minimum(["soft_delete_policy", 0, "retention_duration_seconds"]) and
      known(["lifecycle_rule"]) and
      ((.before | delete_rules) == (.after | delete_rules))
    elif $type == "google_secret_manager_secret" then
      # The provider uses duration strings, so preserve the reviewed delay exactly.
      preserve(["version_destroy_ttl"])
    elif $type == "google_compute_instance_template" then
      (.before | preserved_disks) as $disks
      | ($disks | length) == 0 or (
          ((.after | preserved_disks) == $disks) and
          (. as $change | all(.after.disk | to_entries[] | select(.value.auto_delete == false);
            .key as $index | all(["device_name", "source", "mode", "auto_delete"][];
              . as $key | $change | known(["disk", $index, $key]))))
        )
    elif $type == "google_compute_instance_group_manager" then
      preserve(["stateful_disk"]) and preserve(["stateful_internal_ip"])
    elif $type == "google_compute_resource_policy" then
      preserve(["snapshot_schedule_policy"])
    elif $type == "google_cloud_scheduler_job" then
      preserve(["schedule"]) and preserve(["time_zone"]) and keep(["paused"]; false)
    else true end);

(.errored == null or .errored == false) and
(.format_version | type == "string" and test("^1\\.[0-9]+$")) and
((if .checks == null then [] else .checks end) | type == "array" and
  all(.[]; .status == "pass" and
    ((if .instances == null then [] else .instances end) | type == "array" and
      all(.[]; .status == "pass")))) and
all((.resource_changes // [])[];
  .mode == "data" or (
    .mode == "managed" and
    (if .change.actions == ["delete"] or .change.actions == ["forget"] then true
     elif .change.before == null and .change.actions == ["create"] then true
     else
       (.change.before | type) == "object" and
       (.change.after | type) == "object" and protections
     end)
  )
)
