package tests_test

import (
	"testing"
)

var schedules = []struct{ address, name, cron string }{
	{"json_keys_rotation[0]", "agora-json-keys-rotation", "10 * * * *"},
	{`postgres_backup["authentication"]`, "agora-postgres-backup-authentication", "45 */4 * * *"},
	{`postgres_backup["json_keys"]`, "agora-postgres-backup-json-keys", "15 */4 * * *"},
	{`postgres_restore["authentication"]`, "agora-postgres-restore-authentication", "45 3 1 * *"},
	{`postgres_restore["json_keys"]`, "agora-postgres-restore-json-keys", "15 3 1 * *"},
	{"postgres_backup_monitor[0]", "agora-postgres-backup-monitor", "5 * * * *"},
}

func schedulePlan(index int, phase string) object {
	schedule := schedules[index]
	values := func(paused bool) object {
		return object{"name": schedule.name, "project": "fixture-project", "region": "europe-west1", "schedule": schedule.cron, "time_zone": "Etc/UTC", "paused": paused}
	}
	value := plan("google_cloud_scheduler_job", values(phase != "candidate"), values(phase == "candidate"))
	resource(value)["address"] = "google_cloud_scheduler_job." + schedule.address
	nested(resource(value), "change")["after_unknown"] = object{"last_attempt_time": true}
	value["variables"] = object{
		"application_release": object{"value": object{"rollout": object{"phase": phase, "services": []string{"json_keys"}}}},
		"recovery_mode":       object{"value": false}, "workload_project_id": object{"value": "fixture-project"},
		"region": object{"value": "europe-west1"}, "private_fixture": object{"value": privateValue},
	}
	return value
}

func TestCandidateSchedule(t *testing.T) {
	t.Parallel()
	for index, schedule := range schedules {
		for _, phase := range []string{"candidate", "active"} {
			t.Run(schedule.name+"/"+phase, func(t *testing.T) {
				t.Parallel()
				setup(t).summary(t, "release", schedulePlan(index, phase), 0)
			})
		}
	}
	cases := []struct {
		name   string
		mutate func(object)
	}{
		{"Unrelated", func(p object) { resource(p)["address"] = "google_cloud_scheduler_job.unrelated" }},
		{"ChildModule", func(p object) { resource(p)["address"] = "module.other." + resource(p)["address"].(string) }},
		{"Replacement", func(p object) { nested(resource(p), "change")["actions"] = []string{"delete", "create"} }},
		{"DeletionProtection", func(p object) {
			nested(resource(p), "change", "before")["deletion_protection"] = true
			nested(resource(p), "change", "after")["deletion_protection"] = false
		}},
		{"UnknownResource", func(p object) { nested(resource(p), "change")["after_unknown"] = true }},
		{"MissingPause", func(p object) { delete(nested(resource(p), "change", "after"), "paused") }},
		{"MissingPhase", func(p object) { delete(nested(p, "variables", "application_release", "value", "rollout"), "phase") }},
		{"AbsentApplication", func(p object) { nested(p, "variables", "application_release")["value"] = nil }},
		{"Recovery", func(p object) { nested(p, "variables", "recovery_mode")["value"] = true }},
		{"UnresolvedCheck", func(p object) { p["checks"] = []any{object{"status": "unknown"}} }},
	}
	for _, phase := range []string{"active", "unknown"} {
		cases = append(cases, struct {
			name   string
			mutate func(object)
		}{"Phase/" + phase, func(p object) { nested(p, "variables", "application_release", "value", "rollout")["phase"] = phase }})
	}
	for _, field := range []string{"recovery_mode", "workload_project_id", "region"} {
		cases = append(cases, struct {
			name   string
			mutate func(object)
		}{"Missing/" + field, func(p object) { delete(nested(p, "variables"), field) }})
	}
	for _, field := range []string{"paused", "name", "project", "region", "schedule", "time_zone"} {
		cases = append(cases, struct {
			name   string
			mutate func(object)
		}{"Unknown/" + field, func(p object) { nested(resource(p), "change", "after_unknown")[field] = true }})
		if field == "paused" {
			continue
		}
		for _, both := range []bool{false, true} {
			name := "Changed/"
			if both {
				name = "Wrong/"
			}
			// Schedule and zone must be unchanged; identity must also match the plan.
			if both && (field == "schedule" || field == "time_zone") {
				continue
			}
			cases = append(cases, struct {
				name   string
				mutate func(object)
			}{name + field, func(p object) {
				nested(resource(p), "change", "after")[field] = "other"
				if both {
					nested(resource(p), "change", "before")[field] = "other"
				}
			}})
		}
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			value := schedulePlan(0, "candidate")
			testCase.mutate(value)
			f := setup(t)
			f.env["ALLOW_RESOURCE_DELETION"] = "true"
			f.summary(t, "release", value, 65)
		})
	}
	for _, root := range []string{"bootstrap", "foundation"} {
		t.Run(root, func(t *testing.T) {
			t.Parallel()
			setup(t).summary(t, root, schedulePlan(0, "candidate"), 65)
		})
	}
}
