package tests_test

import "testing"

func TestScheduleProtection(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name  string
		after object
		code  int
	}{
		{"Success/Unchanged", object{"schedule": "10 * * * *", "time_zone": "Etc/UTC", "paused": false}, 0},
		{"Error/Pause", object{"schedule": "10 * * * *", "time_zone": "Etc/UTC", "paused": true}, 65},
		{"Error/Schedule", object{"schedule": "20 * * * *", "time_zone": "Etc/UTC", "paused": false}, 65},
		{"Error/TimeZone", object{"schedule": "10 * * * *", "time_zone": "Europe/Paris", "paused": false}, 65},
		{"Error/UnknownPause", object{"schedule": "10 * * * *", "time_zone": "Etc/UTC"}, 65},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			value := plan("google_cloud_scheduler_job", object{"schedule": "10 * * * *", "time_zone": "Etc/UTC", "paused": false}, testCase.after)
			resource(value)["address"] = "google_cloud_scheduler_job.json_keys_rotation[0]"
			f := setup(t)
			f.env["ALLOW_RESOURCE_DELETION"] = "true"
			f.summary(t, "foundation", value, testCase.code)
		})
	}
}
