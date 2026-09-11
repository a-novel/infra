# Image releases may mutate only their selected family. Unknown/new addresses
# need a reviewed ownership rule or a separate full-state maintenance release.
def owned($service):
  [
    "google_cloud_run_v2_service.\($service)[0]",
    "google_tags_location_tag_binding.\($service)[0]",
    "google_cloud_run_v2_job.application[\"\($service)_migrations\"]",
    "google_tags_location_tag_binding.application[\"\($service)_migrations\"]",
    "google_cloud_run_v2_job.postgres_backup[\"\($service)\"]",
    "google_cloud_run_v2_job.postgres_restore[\"\($service)\"]",
    "google_tags_location_tag_binding.postgres_backup[\"\($service)\"]",
    "google_tags_location_tag_binding.postgres_restore[\"\($service)\"]"
  ] + (if $service == "json_keys" then [
    "google_cloud_run_v2_job.application[\"json_keys_rotate\"]",
    "google_tags_location_tag_binding.application[\"json_keys_rotate\"]",
    "google_cloud_scheduler_job.json_keys_rotation[0]",
    "google_cloud_run_v2_job.json_keys_smoke[0]",
    "google_tags_location_tag_binding.json_keys_smoke[0]"
  ] else [] end);

# Pause only the selected service\'s backup schedules without changing their contract.
def recovery_schedule_toggle($phase; $service):
  .address as $address |
  ([
    "google_cloud_scheduler_job.postgres_backup[\"\($service)\"]",
    "google_cloud_scheduler_job.postgres_restore[\"\($service)\"]"
  ] | index($address)) != null and
  (.change |
    .actions == ["update"] and .importing == null and
    (.before.paused | type == "boolean") and
    .after.paused == ($phase == "candidate") and
    # State is the provider-computed ENABLED/PAUSED status.
    (.before | del(.paused, .state)) == (.after | del(.paused, .state)) and
    ([.after_unknown | del(.state) | .. | select(. == true)] | length == 0));

(.variables.application_release.value.rollout.services // ["json_keys", "authentication"]) as $services |
(.variables.application_release.value.rollout.phase // "active") as $phase |
if $services != $expected_services then false
elif ($services | sort) == ["authentication", "json_keys"] then true
elif $services == ["json_keys"] or $services == ["authentication"] then
  owned($services[0]) as $owned |
  all((.resource_changes // [])[];
    .mode == "data" or (
      .mode == "managed" and .previous_address == null and (
        (.change.actions == ["no-op"] and .change.importing == null) or
        (.address as $address | ($owned | index($address)) != null) or
        recovery_schedule_toggle($phase; $services[0])
      )
    ))
else false end
