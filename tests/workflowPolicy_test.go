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
	Needs       any
	Outputs     map[string]string
	Permissions map[string]string
	Steps       []workflowStep
}

func TestVerifierArtifact(t *testing.T) {
	t.Parallel()
	publication := loadWorkflow(t, "workflows/publish-rollout-verifier.yaml")
	build, publish := publication.Jobs["build"], publication.Jobs["publish"]
	action := loadWorkflow(t, "actions/build-rollout-verifier/action.yaml").Runs.Steps
	image := action[stepIndex(t, action, "docker/build-push-action@")]
	scan := action[stepIndex(t, action, "aquasecurity/trivy-action@")]
	upload := build.Steps[stepIndex(t, build.Steps, "actions/upload-artifact@")]
	download := publish.Steps[stepIndex(t, publish.Steps, "actions/download-artifact@")]
	attest := publish.Steps[stepIndex(t, publish.Steps, "actions/attest@")]
	for _, testCase := range []struct {
		name           string
		actual, expect any
	}{
		{"ManualOnly", len(publication.On), 1},
		{"PublicationOffByDefault", nested(publication.On, "workflow_dispatch", "inputs", "publish")["default"], false},
		{"NoInheritedAuthority", publication.Permissions, map[string]string{}},
		{"ReadOnlyBuild", build.Permissions, map[string]string{"contents": "read"}},
		{"Approval", publish.Environment, "rollout-artifacts"},
		{"PublishAuthority", publish.Permissions, map[string]string{"contents": "read", "packages": "write", "attestations": "write", "id-token": "write"}},
		{"SameRunArtifact", publish.Needs, "build"},
		{"ExactArtifactOutput", build.Outputs, map[string]string{"artifact_id": "${{ steps.archive.outputs.artifact-id }}"}},
		{"ExactArtifactInput", download.With, object{"artifact-ids": "${{ needs.build.outputs.artifact_id || '0' }}", "path": "${{ runner.temp }}", "merge-multiple": true, "digest-mismatch": "error"}},
		{"OnlyImageArchive", upload.With["path"], "${{ runner.temp }}/rollout-verifier.tar"},
		{"MissingArchiveFails", upload.With["if-no-files-found"], "error"},
		{"NoBuildPush", image.With["push"], false},
		{"SinglePlatform", image.With["platforms"], "linux/amd64"},
		{"ScannedArchive", image.With["outputs"], "type=docker,dest=" + scan.With["input"].(string)},
		{"BlockingScan", []any{scan.With["scanners"], scan.With["severity"], scan.With["exit-code"]}, []any{"vuln,secret", "HIGH,CRITICAL", "1"}},
		{"AttestedDigest", attest.With, object{"subject-name": "ghcr.io/a-novel/infra/rollout-verifier", "subject-digest": "${{ steps.publish.outputs.digest }}", "push-to-registry": true, "create-storage-record": false}},
		{"NoCancellation", publication.Concurrency["cancel-in-progress"], false},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			require.Equal(t, testCase.expect, testCase.actual)
		})
	}
	t.Run("TrustBoundary", func(t *testing.T) {
		t.Parallel()
		require.Contains(t, publish.If, "inputs.publish && vars.ROLLOUT_VERIFIER_PUBLICATION_ENABLED == 'true'")
		require.Contains(t, publish.If, "github.repository == 'a-novel/infra' && github.ref == 'refs/heads/master'")
		encoded, err := json.Marshal(publish)
		require.NoError(t, err)
		require.NotRegexp(t, `checkout@|google-github-actions|secrets\.|build-push-action|docker (build|run)|go run|go build`, string(encoded))
		for _, steps := range [][]workflowStep{build.Steps, loadWorkflow(t, "workflows/main.yaml").Jobs["scan-infrastructure"].Steps} {
			stepIndex(t, steps, "./.github/actions/build-rollout-verifier")
		}
		for _, pair := range [][2]string{{"actions/download-artifact@", "docker load"}, {"docker load", "docker/login-action@"}, {"docker/login-action@", "docker push"}, {"docker push", "actions/attest@"}, {"actions/attest@", "GITHUB_STEP_SUMMARY"}} {
			require.Less(t, stepIndex(t, publish.Steps, pair[0]), stepIndex(t, publish.Steps, pair[1]))
		}
		require.Less(t, stepIndex(t, build.Steps, "./.github/actions/build-rollout-verifier"), stepIndex(t, build.Steps, "actions/upload-artifact@"))
		require.Less(t, stepIndex(t, action, "docker/build-push-action@"), stepIndex(t, action, "aquasecurity/trivy-action@"))
	})
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
