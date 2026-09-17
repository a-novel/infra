package tests_test

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestInitializationMarker(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, path, key, value, failure string
		code                            int
		prompt                          bool
	}{
		{name: "Success", code: 0},
		{name: "WrongProject", key: "project", value: "another-project", code: 70},
		{name: "WrongDisk", key: "dataDiskId", value: "1002", code: 70},
		{name: "WrongExecution", key: "execution", value: "different-job-abc", code: 70},
		{name: "ListDenied", failure: "LIST", code: 70},
		{name: "ReadDenied", failure: "READ", code: 70},
		{name: "Lookalike", path: "1001/complete.json.backup", code: 70, prompt: true},
		{name: "Legacy", path: "complete.json", code: 70, prompt: true},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			f.fake(t, "gcloud", "fake-gcloud-storage.sh")
			date, err := exec.LookPath("date")
			require.NoError(t, err)
			f.link(t, "date", date)
			f.env["FAKE_GCS_ROOT"], f.env["INITIALIZATION_MAX_POLLS"], f.env["INITIALIZATION_POLL_SECONDS"] = f.dir, "1", "0"
			f.env["FAKE_GCS_"+testCase.failure+"_FAILURE"] = "true"
			marker := object{"schemaVersion": 2, "project": "workload-test", "dataDiskId": "1001", "commit": strings.Repeat("a", 40), "execution": "agora-authentication-init-previous", "completedAt": "2026-09-17T12:00:00Z"}
			name := "1001/complete.json"
			if testCase.path != "" {
				name = testCase.path
			}
			if testCase.key != "" {
				marker[testCase.key] = testCase.value
			}
			if testCase.name == "Legacy" {
				marker["schemaVersion"] = 1
				delete(marker, "dataDiskId")
			}
			writeJSON(t, filepath.Join(f.dir, "fixture-bucket/production/initialization", name), marker)
			code, out := f.script(t, "await-auth-initialization", "workload-test", "europe-west1", "fixture-bucket", strings.Repeat("b", 40), "1001")
			expectCode(t, testCase.code, code, out)
			require.Equal(t, testCase.prompt, strings.Contains(out, "human-only initialization"))
			if testCase.code == 0 {
				require.Equal(t, "agora-authentication-init-previous\n", out)
			}
		})
	}
}
