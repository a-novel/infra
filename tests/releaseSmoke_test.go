package tests_test

import (
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestAuthenticationSmoke(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, ready    string
		lookup, health int
		code           int
	}{
		{"Success", "True", 0, 0, 0},
		{"NotReady", "False", 0, 0, 70},
		{"LookupFailed", "True", 1, 0, 70},
		{"Unhealthy", "True", 0, 70, 70},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := driverFixture(t)
			release := readJSON(t, filepath.Join(f.dir, "release.json"))
			nested(release, "revisions")["authentication"] = "auth-candidate"
			release["candidateTag"] = "candidate"
			writeJSON(t, filepath.Join(f.dir, "release.json"), release)
			operations := object{"health": object{"authentication": "not-run", "jsonKeys": "not-run"}}
			writeJSON(t, filepath.Join(f.dir, "operations.json"), operations)
			f.command(t, "gcloud")
			f.command(t, "infra")
			calls := []invocation{{Name: "gcloud", Args: []string{"run", "revisions", "describe", "auth-candidate", "--project=fixture-project", "--region=europe-west1", "--format=json"}, Output: `{"status":{"conditions":[{"type":"Ready","status":"` + testCase.ready + `"}]}}`}}
			if testCase.ready == "True" {
				calls = append(calls, invocation{Name: "gcloud", Args: []string{"run", "services", "describe", "agora-authentication-rest", "--project=fixture-project", "--region=europe-west1", "--format=json"}, Output: `{"status":{"traffic":[{"tag":"candidate","url":"https://candidate.run.app"}]}}`, Code: testCase.lookup})
				if testCase.lookup == 0 {
					calls = append(calls, invocation{Name: "infra", Args: []string{"check-health", "candidate", "https://candidate.run.app"}, Code: testCase.health})
				}
			}
			f.expect(t, calls)
			code, output := f.script(t, "google-release-driver", "authentication-smoke")
			expectCode(t, testCase.code, code, output)
			require.JSONEq(t, "[]", read(t, f.env["INFRA_TEST_SEQUENCE"]))
			if testCase.code == 0 {
				nested(operations, "health")["authentication"] = "passed"
			}
			require.Equal(t, operations, readJSON(t, filepath.Join(f.dir, "operations.json")))
		})
	}
}
