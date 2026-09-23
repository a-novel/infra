package tests_test

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestDeletionAssessment(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name        string
		config      object
		files       string
		failure     string
		firstLaunch bool
		code        int
	}{
		{"MissingConfig", nil, "image", "", true, 0},
		{"EmptyRollback", object{"application_release": nil, "database_releases": object{}}, "image", "", true, 0},
		{"OmittedApplication", object{"database_releases": object{}}, "image", "", true, 0},
		{"Established", object{"application_release": object{"rollout": object{"phase": "active"}}}, "image", "", false, 0},
		{"CleanPlan", object{"application_release": nil}, "release", "", true, 0},
		{"FailedPlan", object{"application_release": nil}, "release", "plan", true, 70},
		{"ListFailure", object{"application_release": nil}, "image", "FAKE_GCS_LIST_FAILURE", true, 70},
		{"ReadFailure", object{"application_release": nil}, "image", "FAKE_GCS_READ_FAILURE", true, 70},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			git, err := exec.LookPath("git")
			require.NoError(t, err)
			f.link(t, "git", git)
			candidate := filepath.Join(f.dir, "candidate")
			code, out := f.run(t, "git", "init", "-q", "-b", "master", candidate)
			expectCode(t, 0, code, out)
			code, out = f.run(t, "git", "-C", candidate, "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "fixture")
			expectCode(t, 0, code, out)
			code, out = f.run(t, "git", "-C", candidate, "rev-parse", "HEAD")
			expectCode(t, 0, code, out)
			head, base := strings.TrimSpace(out), strings.Repeat("b", 40)
			f.fake(t, "gh", "fake-deletion-gate-gh.sh")
			f.fake(t, "gcloud", "fake-gcloud-storage.sh")
			f.command(t, "infra")
			f.fake(t, "tofu", "fake-tofu.sh")
			storage := filepath.Join(f.dir, "storage")
			if testCase.config != nil {
				testCase.config["privateValue"] = privateValue
				writeJSON(t, filepath.Join(storage, "agora-state-test/release/config/00000000000000000001-00013.tfvars.json"), testCase.config)
			}
			f.env["FAKE_GATE_HEAD"], f.env["FAKE_GATE_BASE"], f.env["FAKE_GATE_FILES"] = head, base, testCase.files
			f.env["FAKE_GCS_ROOT"], f.env["FAKE_TOFU_PLAN_CODE"] = storage, "0"
			f.env["FAKE_TOFU_PLAN_JSON"] = filepath.Join(f.root, "tests/fixtures/plans/no-changes.json")
			if testCase.failure == "plan" {
				f.env["FAKE_TOFU_FAIL_ACTION"] = "plan"
			} else if testCase.failure != "" {
				f.env[testCase.failure] = "true"
			}
			output := filepath.Join(f.dir, "assessment.json")
			code, out = f.run(t, "infra", "inspect", "assess", "a-novel/infra", "93", head, base, candidate, "agora-state-test", output)
			expectCode(t, testCase.code, code, out)
			if code != 0 {
				require.NoFileExists(t, output)
				return
			}
			require.Equal(t, object{
				"schemaVersion": float64(1), "repository": "a-novel/infra", "pullRequest": float64(93),
				"headSha": head, "baseSha": base, "firstLaunch": testCase.firstLaunch, "approvalRequired": testCase.firstLaunch,
			}, readJSON(t, output))
			if testCase.firstLaunch {
				require.NotContains(t, out, "established release")
			}
			if testCase.files == "release" {
				require.Contains(t, out, "release assess completed")
			}
		})
	}
}
