package tests_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"go.yaml.in/yaml/v3"
)

type workflow struct {
	On          object
	Permissions map[string]string
	Concurrency object
	Jobs        map[string]workflowJob
	Runs        workflowJob
}

type workflowJob struct {
	If          string
	Environment any
	Permissions map[string]string
	Steps       []workflowStep
}

type workflowStep struct {
	Name, Uses, Run, If string
	With                object
	Env                 map[string]string
}

func loadWorkflow(t *testing.T, name string) workflow {
	t.Helper()
	var value workflow
	require.NoError(t, yaml.Unmarshal([]byte(read(t, "../.github/"+name)), &value))
	return value
}

func stepIndex(t *testing.T, steps []workflowStep, match string) int {
	t.Helper()
	for index, step := range steps {
		if strings.Contains(step.Uses+step.Run, match) {
			return index
		}
	}
	t.Fatalf("missing workflow step containing %q", match)
	return -1
}

func TestWorkflowCredentials(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct{ file, job string }{
		{"release", "release"},
		{"release", "database-isolation"},
		{"recovery", "recover"},
		{"foundation", "execute"},
		{"drift", "health"},
		{"drift", "inspect"},
		{"drift", "assess-resource-deletion"},
	} {
		t.Run(testCase.file+"/"+testCase.job, func(t *testing.T) {
			t.Parallel()
			job := loadWorkflow(t, "workflows/"+testCase.file+".yaml").Jobs[testCase.job]
			build := stepIndex(t, job.Steps, "$/.github/actions/setup-infra")
			for index, step := range job.Steps {
				encoded, err := json.Marshal(step)
				require.NoError(t, err)
				if strings.Contains(string(encoded), "secrets.") || strings.Contains(step.Uses, "google-github-actions/auth@") {
					require.Less(t, build, index, "build must precede %s", step.Name)
				}
				require.NotRegexp(t, `setup-node|pnpm|go run|go build`, string(encoded))
			}
		})
	}
	build := loadWorkflow(t, "actions/setup-infra/action.yaml").Runs.Steps
	require.Equal(t, false, build[0].With["cache"])
	require.Contains(t, build[1].Run, "go build -mod=readonly")
	stepIndex(t, loadWorkflow(t, "workflows/main.yaml").Jobs["lint-repository"].Steps, "$/.github/actions/setup-infra")
}

func TestWorkflowBoundaries(t *testing.T) {
	t.Parallel()
	main := loadWorkflow(t, "workflows/main.yaml")
	drift := loadWorkflow(t, "workflows/drift.yaml")
	release := loadWorkflow(t, "workflows/release.yaml")
	renovate := loadWorkflow(t, "workflows/renovate.yaml")
	for _, testCase := range []struct {
		name        string
		workflow    workflow
		job         workflowJob
		permissions map[string]string
	}{
		{"DeletionGate", main, main.Jobs["resource-deletion-gate"], map[string]string{"actions": "read", "contents": "read", "pull-requests": "read"}},
		{"Health", drift, drift.Jobs["health"], map[string]string{"contents": "read", "id-token": "write"}},
		{"Assessment", drift, drift.Jobs["assess-resource-deletion"], map[string]string{"actions": "read", "contents": "read", "id-token": "write", "pull-requests": "read"}},
		{"Renovate", renovate, renovate.Jobs["renovate"], map[string]string{"contents": "read", "packages": "read"}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			require.Empty(t, testCase.workflow.Permissions)
			require.Equal(t, testCase.permissions, testCase.job.Permissions)
			require.Nil(t, testCase.job.Environment)
		})
	}

	gate := main.Jobs["resource-deletion-gate"]
	require.Contains(t, main.On, "merge_group")
	require.ElementsMatch(t, []any{"opened", "reopened", "synchronize", "labeled", "unlabeled"}, nested(main.On, "pull_request")["types"])
	checkout := gate.Steps[stepIndex(t, gate.Steps, "actions/checkout@")].With
	require.Equal(t, false, checkout["persist-credentials"])
	require.Contains(t, checkout["ref"], "pull_request.base.sha")
	require.Contains(t, checkout["ref"], "merge_group.base_sha")
	stepIndex(t, gate.Steps, "verify-resource-deletion-gate.sh")
	encoded, err := json.Marshal(gate)
	require.NoError(t, err)
	require.NotRegexp(t, `secrets\.|google-github-actions/auth`, string(encoded))

	assessment := drift.Jobs["assess-resource-deletion"]
	auth := stepIndex(t, assessment.Steps, "google-github-actions/auth@")
	for _, command := range []string{"resolve-resource-deletion-assessment.sh", "infra assess-images verify"} {
		index := stepIndex(t, assessment.Steps, command)
		require.Less(t, index, auth)
		require.Equal(t, "${{ github.token }}", assessment.Steps[index].Env["GH_TOKEN"])
	}
	require.Equal(t, "trusted", assessment.Steps[stepIndex(t, assessment.Steps, "setup-infra")].With["working_directory"])
	candidates := 0
	for _, step := range assessment.Steps {
		if step.With["path"] == "candidate" {
			candidates++
			require.Equal(t, "${{ inputs.head_sha }}", step.With["ref"])
			require.Equal(t, "${{ steps.target.outputs.repository }}", step.With["repository"])
			require.Equal(t, false, step.With["persist-credentials"])
		}
	}
	require.Equal(t, 1, candidates)
	verdict := assessment.Steps[stepIndex(t, assessment.Steps, "actions/upload-artifact@")]
	require.Equal(t, "${{ runner.temp }}/resource-deletion/assessment.json", verdict.With["path"])
	prepare := assessment.Steps[stepIndex(t, assessment.Steps, "prepare-resource-deletion-assessment.sh")]
	require.Equal(t, "${{ github.token }}", prepare.Env["GH_TOKEN"])

	health := drift.Jobs["health"]
	require.Contains(t, health.If, "vars.PRODUCTION_RELEASES_ENABLED == 'true'")
	require.Equal(t, "${{ vars.GCP_PLAN_SERVICE_ACCOUNT }}", health.Steps[stepIndex(t, health.Steps, "google-github-actions/auth@")].With["service_account"])
	check := health.Steps[stepIndex(t, health.Steps, "infra check-health deployed")]
	require.Contains(t, check.Run, "infra custody config fetch")
	require.NotRegexp(t, `\b(cat|tee)\b|set -x`, check.Run)

	job := release.Jobs["release"]
	compile := stepIndex(t, job.Steps, `"${PRIOR_RECEIPT}" "${RUNNER_TEMP}/release"`)
	require.Contains(t, job.Steps[compile].Run, "infra compile-release")
	require.Less(t, compile, stepIndex(t, job.Steps, "release-orchestrator.sh"))
	require.Equal(t, "${{ steps.prior.outputs.argument }}", job.Steps[compile].Env["PRIOR_RECEIPT"])
	require.Equal(t, object{"group": "production-infrastructure", "cancel-in-progress": false}, release.Concurrency)
	require.Equal(t, map[string]string{"actions": "read", "attestations": "read", "contents": "read", "id-token": "write", "pull-requests": "read"}, job.Permissions)
	verify := stepIndex(t, job.Steps, "actions/runs/${FAILED_RUN_ID}")
	recoverIndex := stepIndex(t, job.Steps, "infra database-release recover-first-launch")
	require.Less(t, verify, recoverIndex)
	for _, index := range []int{verify, recoverIndex} {
		require.Equal(t, "env.RELEASE_ACTION == 'recover-first-launch'", job.Steps[index].If)
	}
	require.Contains(t, job.Steps[verify].Run, `.conclusion == "failure"`)
	require.Contains(t, job.Steps[verify].Run, "production deploy by @")

	require.Len(t, renovate.On, 2)
	require.Contains(t, renovate.On, "workflow_dispatch")
	require.NotEmpty(t, renovate.On["schedule"])
	require.Equal(t, "github.ref == 'refs/heads/master'", renovate.Jobs["renovate"].If)
	step := renovate.Jobs["renovate"].Steps[0]
	require.Contains(t, step.Uses, "a-novel-kit/workflows/generic-actions/renovate@")
	require.Equal(t, object{"github_token": "${{ github.token }}", "app_private_key": "${{ secrets.DEPENDENCY_BOT_PRIVATE_KEY }}", "client_id": "${{ vars.DEPENDENCY_BOT_CLIENT_ID }}"}, step.With)
}
