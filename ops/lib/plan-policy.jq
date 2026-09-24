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

# Bucket retention uses decimal strings; soft-delete retention uses numbers.
# Keep comparisons within jq's exact integer range.
def seconds:
  (if type == "string" and test("\\A[0-9]+\\z") then tonumber else . end)
  | if type == "number" and . >= 0 and . <= 9007199254740991 and . == floor
    then . else error("Invalid retention duration.") end;

def minimum($path):
  (.before | getpath($path)) as $before
  | if $before == null then true else
      (.after | getpath($path)) as $after
      | known($path) and
        ($after | seconds) >= ($before | seconds)
    end;

def delete_rules:
  [.lifecycle_rule[]? | select(any(.action[]; .type == "Delete"))]
  | sort_by(tojson);

# Conditions are intersected by Cloud Storage. These selectors exclude state,
# locks and configuration even if the provider supplies additional conditions.
def service_plan_expiration:
  (.action | length) == 1 and .action[0].type == "Delete" and
  (.condition | length) == 1 and
  (.condition[0] | .age == 2 and .matches_prefix == ["services/"] and
    (.matches_suffix | sort) == ["/plan.metadata.json", "/plan.tfplan"]);

# Only bootstrap may add this rule to its existing state bucket. Every existing
# Delete rule must retain its JSON value, including this one in subsequent plans.
def add_service_plan_expiration($plan):
  $plan.variables.management_project_id.value as $project
  | $root_name == "bootstrap" and .address == "google_storage_bucket.state" and
    ($project | type == "string" and test("\\A[a-z][a-z0-9-]{4,28}[a-z0-9]\\z")) and
    (.change | (.before | delete_rules) as $before | (.after | delete_rules) as $after
      | ($after - $before) as $added
      | .actions == ["update"] and preserve(["project"]) and preserve(["name"]) and
      .after.project == $project and
      (.after.name | test("\\A" + $project + "-[1-9][0-9]*-tofu-state\\z")) and
      ($before - $after) == [] and ($after | length) == ($before | length) + 1 and
      ($added | length) == 1 and ($added[0] | service_plan_expiration));

def preserved_disks:
  [.disk[]? | select(.auto_delete == false) | {device_name, source, mode, auto_delete}]
  | sort_by(.device_name);

# Candidate reconciliation suspends scheduled work until activation or rollback.
# The exception is bound to the saved plan's phase and exact release resources.
def candidate_schedule_pause($plan):
  {
    "google_cloud_scheduler_job.json_keys_rotation[0]": "agora-json-keys-rotation",
    "google_cloud_scheduler_job.postgres_backup[\"authentication\"]": "agora-postgres-backup-authentication",
    "google_cloud_scheduler_job.postgres_backup[\"json_keys\"]": "agora-postgres-backup-json-keys",
    "google_cloud_scheduler_job.postgres_restore[\"authentication\"]": "agora-postgres-restore-authentication",
    "google_cloud_scheduler_job.postgres_restore[\"json_keys\"]": "agora-postgres-restore-json-keys",
    "google_cloud_scheduler_job.postgres_backup_monitor[0]": "agora-postgres-backup-monitor"
  }[.address] as $name
  | $root_name == "release" and $name != null and
    $plan.variables.application_release.value.rollout.phase == "candidate" and
    $plan.variables.recovery_mode.value == false and
    (.change | .actions == ["update"] and
      preserve(["name"]) and preserve(["project"]) and preserve(["region"]) and
      known(["paused"]) and .before.paused == false and .after.paused == true and
      .after.name == $name and
      (.after.project | type == "string" and length > 0) and
      (.after.region | type == "string" and length > 0) and
      .after.project == $plan.variables.workload_project_id.value and
      .after.region == $plan.variables.region.value);

def protections($plan):
  . as $resource | .type as $type | .change
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
      (((.before | delete_rules) == (.after | delete_rules)) or
        ($resource | add_service_plan_expiration($plan)))
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
      preserve(["schedule"]) and preserve(["time_zone"]) and
      (keep(["paused"]; false) or ($resource | candidate_schedule_pause($plan)))
    else true end);

# Bootstrap creates jobs in their final state. Existing jobs belong to routine
# release; imports and address moves require separately reviewed reconciliation.
def service_job_bootstrap:
  .variables.project_id.value as $project | .variables.service.value as $service |
  .variables.region.value as $region |
  (if $service == "json-keys" then ["migrations", "rotatekeys"]
   elif $service == "authentication" then ["migrations"] else [] end) as $roles |
  ($roles | length > 0) and $ENV.TOFU_STATE_SUFFIX == "services/" + $project and
  all((.resource_changes // [])[];
    .mode == "managed" and .type == "google_cloud_run_v2_job" and
    (.index as $role | $roles | index($role) != null) and
    .address == "google_cloud_run_v2_job.application[" + (.index | tojson) + "]" and
    .previous_address == null and .deposed == null and .change.importing == null and
    (.change.actions == ["create"] or .change.actions == ["no-op"]) and
    .change.after.name == "agora-" + $service + "-" + .index and
    (.change | . as $change | .after.project == $project and .after.location == $region and
      .after.deletion_protection == true and
      all(["project", "location", "name", "deletion_protection"][];
        . as $field | $change | known([$field])))
  );

. as $plan |
($root_name != "service-release" or $ENV.SERVICE_JOB_BOOTSTRAP != "true" or service_job_bootstrap) and
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
       (.change.after | type) == "object" and protections($plan)
     end)
  )
)
