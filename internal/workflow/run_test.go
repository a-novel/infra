package workflow_test

import (
	"fmt"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestRun(t *testing.T) {
	t.Parallel()
	testCases := []struct {
		args, fields []string
		output       string
	}{
		{[]string{"drift"}, []string{"operation=drift"}, "202"},
		{[]string{"drift", "observe-rollout", "json-keys", "release-123", "production"}, []string{"operation=observe-rollout", "service=json-keys", "release_id=release-123", "rollout_id=production"}, "202"},
		{[]string{"drift", "assess-pull-request", "93"}, []string{"operation=assess-pull-request", "pull_request=93", "head_sha=" + head, "base_sha=" + sha}, "202"},
		{[]string{"foundation", "plan", "bootstrap"}, []string{"operation=plan", "root=bootstrap"}, "202-3"},
		{[]string{"foundation", "plan", "foundation"}, []string{"operation=plan", "root=foundation"}, "202-3"},
		{[]string{"foundation", "plan", "service-foundation", "json-keys"}, []string{"operation=plan", "root=service-foundation", "service=json-keys"}, "202-3"},
		{[]string{"foundation", "apply", "service-foundation", "authentication", "101-3"}, []string{"operation=apply", "root=service-foundation", "service=authentication", "plan_id=101-3"}, "202"},
		{[]string{"foundation", "plan", "service-release", "json-keys"}, []string{"operation=plan", "root=service-release", "service=json-keys"}, "202-3"},
		{[]string{"foundation", "apply", "service-release", "authentication", "101-3"}, []string{"operation=apply", "root=service-release", "service=authentication", "plan_id=101-3"}, "202"},
		{[]string{"foundation", "promote-images", "service-release", "json-keys"}, []string{"operation=promote-images", "root=service-release", "service=json-keys"}, "202"},
		{[]string{"foundation", "promote-images", "service-release", "authentication"}, []string{"operation=promote-images", "root=service-release", "service=authentication"}, "202"},
		{[]string{"foundation", "apply", "bootstrap", "101-3"}, []string{"operation=apply", "root=bootstrap", "plan_id=101-3"}, "202"},
		{[]string{"foundation", "apply", "foundation", "101-3"}, []string{"operation=apply", "root=foundation", "plan_id=101-3"}, "202"},
		{[]string{"release", "deploy"}, []string{"action=deploy"}, "202"},
		{[]string{"release", "deploy", "--no-wait"}, []string{"action=deploy"}, "202"},
		{[]string{"release", "rollback", "101-3"}, []string{"action=rollback", "target_receipt=101-3"}, "202"},
		{[]string{"release", "recover-first-launch", "678"}, []string{"action=recover-first-launch", "failed_run_id=678"}, "202"},
		{[]string{"release", "drill-database-isolation", "101-3", "DRILL authentication"}, []string{"action=drill-database-isolation", "target_receipt=101-3", "confirm_isolation=DRILL authentication"}, "202"},
		{[]string{"release", "restore-database-isolation", "101-3", "RESTORE authentication"}, []string{"action=restore-database-isolation", "target_receipt=101-3", "confirm_isolation=RESTORE authentication"}, "202"},
		{[]string{"recovery", "plan-workload", "recovery-project-prod", "101-3"}, []string{"operation=plan-workload", "replacement_project_id=recovery-project-prod", "target_receipt=101-3"}, "202-3"},
		{[]string{"recovery", "apply-workload", "recovery-project-prod", "101-3", "101-3"}, []string{"operation=apply-workload", "replacement_project_id=recovery-project-prod", "target_receipt=101-3", "plan_id=101-3"}, "202"},
		{[]string{"recovery", "restore-data", "recovery-project-prod", "101-3", "100-json-1", "101-auth-1", `@literal {value} = "no known lost writes"`, "RESTORE recovery-project-prod"}, []string{"operation=restore-data", "replacement_project_id=recovery-project-prod", "target_receipt=101-3", "json_keys_attempt=100-json-1", "authentication_attempt=101-auth-1", `lost_write_window=@literal {value} = "no known lost writes"`, "confirm=RESTORE recovery-project-prod"}, "202-3"},
		{[]string{"recovery", "cleanup-project", "recovery-project-prod", "101-3", "DELETE recovery-project-prod"}, []string{"operation=cleanup-project", "replacement_project_id=recovery-project-prod", "target_receipt=101-3", "confirm=DELETE recovery-project-prod"}, "202"},
	}
	for _, testCase := range testCases {
		t.Run(strings.Join(testCase.args, " "), func(t *testing.T) {
			t.Parallel()
			overrides := map[string]string{}
			watches := 1
			if testCase.args[len(testCase.args)-1] == "--no-wait" {
				overrides["run.patch"] = `{"status":"queued","conclusion":null}`
				watches = 0
			}
			r := invoke(t, testCase.args, overrides, "")
			require.Zero(t, r.code, r.stderr.String())
			require.Equal(t, testCase.output+"\n", r.stdout.String())
			require.Contains(t, r.stderr.String(), runURL)
			command := []string{"api", "repos/a-novel/infra/actions/workflows/" + testCase.args[0] + ".yaml/dispatches", "--method", "POST", "-H", "X-GitHub-Api-Version: 2026-03-10", "-f", "ref=master"}
			for _, field := range testCase.fields {
				key, value, _ := strings.Cut(field, "=")
				command = append(command, "-f", "inputs["+key+"]="+value)
			}
			require.Equal(t, [][]string{command}, r.dispatches)
			require.Equal(t, watches, r.watches)
		})
	}
}

func TestRunInvalidIntent(t *testing.T) {
	t.Parallel()
	for _, args := range [][]string{
		nil,
		{"unknown"},
		{"drift", "observe-rollout", "authentication", "release-123", "production"},
		{"drift", "observe-rollout", "json-keys", "release-123"},
		{"drift", "observe-rollout", "json-keys", "release-123", "production", "extra"},
		{"drift", "observe-rollout", "json-keys", "release-123/rollouts/other", "production"},
		{"drift", "observe-rollout", "json-keys", "release-123", "production\n"},
		{"foundation", "plan"},
		{"foundation", "plan", "release"},
		{"foundation", "apply", "foundation", "01-3"},
		{"foundation", "plan", "service-foundation"},
		{"foundation", "plan", "service-foundation", "peer"},
		{"foundation", "apply", "service-foundation", "json-keys", "01-3"},
		{"foundation", "promote-images", "foundation"},
		{"foundation", "promote-images", "service-foundation", "json-keys"},
		{"foundation", "promote-images", "service-release", "peer"},
		{"foundation", "promote-images", "service-release", "json-keys", "101-3"},
		{"release", "deploy", "--force"},
		{"release", "recover-first-launch", "invalid"},
		{"release", "rollback", "101-0"},
		{"release", "drill-database-isolation", "101-3", "DRILL json-keys"},
		{"recovery", "cleanup-project", "recovery-project-prod", "101-3", "DELETE wrong-project"},
		{"recovery", "restore-data", "recovery-project-prod", "101-3", "100-json-1", "101-auth-1", "writes", "RESTORE wrong-project"},
		{"recovery", "restore-data", "recovery-project-prod", "101-3", "100-json-1", "101-auth-1", "writes\n", "RESTORE recovery-project-prod"},
		{"recovery", "restore-data", "recovery-project-prod", "101-3", "100-json-1", "101-auth-1", strings.Repeat("x", 501), "RESTORE recovery-project-prod"},
	} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			t.Parallel()
			r := invoke(t, args, nil, "")
			require.Equal(t, 64, r.code)
			require.Zero(t, r.calls)
			require.Empty(t, r.stdout.String())
		})
	}
}

func TestRunObservationConcurrency(t *testing.T) {
	t.Parallel()
	for _, active := range []string{"303 waiting", ""} {
		t.Run(active, func(t *testing.T) {
			t.Parallel()
			r := invoke(t, []string{"drift", "observe-rollout", "json-keys", "release-123", "production"},
				map[string]string{"active": active}, "active")
			require.Equal(t, 0, r.code, r.stderr.String())
			require.Len(t, r.dispatches, 1)
		})
	}
}

func TestRunPreflight(t *testing.T) {
	t.Parallel()
	for stage, body := range map[string]string{
		"branch": "topic", "status": " M file", "remote": head, "active": "303 waiting",
		"rev-parse": "private-invalid-sha", "plan": "private-invalid-json",
		"plan.patch": `{"head_sha":"` + head + `"}`,
	} {
		t.Run(stage, func(t *testing.T) {
			t.Parallel()
			r := invoke(t, []string{"foundation", "apply", "foundation", "101-3"}, map[string]string{stage: body}, "")
			require.NotZero(t, r.code)
			require.Empty(t, r.dispatches)
			require.Empty(t, r.stdout.String())
			require.NotContains(t, r.stderr.String(), "private-")
		})
	}
	for _, patch := range []string{
		`{"display_title":"foundation apply foundation by @operator"}`, `{"conclusion":"failure"}`,
		`{"run_attempt":4}`, `{"path":".github/workflows/recovery.yaml"}`, `{"event":"push"}`, `{"status":"in_progress"}`,
	} {
		t.Run(patch, func(t *testing.T) {
			t.Parallel()
			r := invoke(t, []string{"foundation", "apply", "foundation", "101-3"}, map[string]string{"plan.patch": patch}, "")
			require.Equal(t, 65, r.code)
			require.Empty(t, r.dispatches)
		})
	}
	for _, patch := range []string{`{"state":"closed"}`, `{"base":{}}`, `{"head":{"sha":"invalid"}}`} {
		t.Run(patch, func(t *testing.T) {
			t.Parallel()
			r := invoke(t, []string{"drift", "assess-pull-request", "93"}, map[string]string{"pr.patch": patch}, "")
			require.Equal(t, 65, r.code)
			require.Empty(t, r.dispatches)
		})
	}
}

func TestRunCommandFailure(t *testing.T) {
	t.Parallel()
	for _, stage := range []string{"branch", "status", "rev-parse", "plan", "remote", "active", "dispatch", "run", "watch", "finished"} {
		t.Run(stage, func(t *testing.T) {
			t.Parallel()
			r := invoke(t, []string{"foundation", "apply", "foundation", "101-3"}, nil, stage)
			require.NotZero(t, r.code)
			require.Empty(t, r.stdout.String())
			require.LessOrEqual(t, len(r.dispatches), 1)
			if len(r.dispatches) == 1 {
				require.Contains(t, r.stderr.String(), "before retrying")
			}
		})
	}
}

func TestRunServicePlanIdentity(t *testing.T) {
	t.Parallel()
	for _, scope := range []string{"service-foundation/json-keys", "service-release/authentication"} {
		t.Run(scope, func(t *testing.T) {
			t.Parallel()
			r := invoke(t, []string{"foundation", "apply", "service-release", "json-keys", "101-3"},
				map[string]string{"plan.patch": `{"display_title":"foundation plan ` + scope + ` by @operator"}`}, "")
			require.Equal(t, 65, r.code)
			require.Empty(t, r.dispatches)
		})
	}
}

func TestRunUncertainDispatch(t *testing.T) {
	t.Parallel()
	bodies := []string{
		"", "private-invalid-json", "{}", "null", "[]", dispatch + dispatch,
		`{"workflow_run_id":202,"html_url":"https://example.invalid/private-url"}`,
	}
	for _, id := range []string{"0", "-1", "1.5", `"202"`, "9007199254740992"} {
		bodies = append(bodies, fmt.Sprintf(`{"workflow_run_id":%s,"html_url":%q}`, id, runURL))
	}
	for _, body := range bodies {
		t.Run(body, func(t *testing.T) {
			t.Parallel()
			r := invoke(t, []string{"release", "deploy", "--no-wait"}, map[string]string{"dispatch": body}, "")
			require.Equal(t, 70, r.code)
			require.Empty(t, r.stdout.String())
			require.Len(t, r.dispatches, 1)
			require.Zero(t, r.watches)
			require.Contains(t, r.stderr.String(), "before retrying")
			require.NotContains(t, r.stderr.String(), "private-")
		})
	}
}

func TestRunIdentityAndCompletion(t *testing.T) {
	t.Parallel()
	for _, stage := range []string{"run", "finished"} {
		for _, patch := range []string{`{"id":999}`, `{"head_sha":"` + head + `"}`, `{"path":"wrong.yaml"}`, `{"event":"push"}`, `{"head_branch":"topic"}`} {
			t.Run(stage+patch, func(t *testing.T) {
				t.Parallel()
				r := invoke(t, []string{"foundation", "plan", "foundation"}, map[string]string{stage + ".patch": patch}, "")
				require.Equal(t, 70, r.code)
				require.Empty(t, r.stdout.String())
				require.Len(t, r.dispatches, 1)
				require.Contains(t, r.stderr.String(), "before retrying")
			})
		}
	}
	for _, patch := range []string{`{"status":"in_progress"}`, `{"conclusion":"failure"}`, `{"conclusion":"skipped"}`, `{"run_attempt":0}`, `{"run_attempt":1.5}`} {
		t.Run(patch, func(t *testing.T) {
			t.Parallel()
			r := invoke(t, []string{"foundation", "plan", "foundation"}, map[string]string{"finished.patch": patch}, "")
			require.Equal(t, 70, r.code)
			require.Empty(t, r.stdout.String())
			require.Len(t, r.dispatches, 1)
			require.Equal(t, 1, r.watches)
		})
	}
}
