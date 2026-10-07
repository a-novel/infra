package custody

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"google.golang.org/api/option"
	"google.golang.org/api/storage/v1"

	"github.com/a-novel/infra/internal/workflow"
)

// recoverLegacyMaintenance reconciles one acknowledged hold after its original
// writer ended. A create-only attempt prevents replay after an uncertain recovery.
func (custody store) recoverLegacyMaintenance(args []string, getenv func(string) string, output io.Writer, options []option.ClientOption) error {
	if len(args) != 3 {
		return failure{64, "Legacy recovery requires the exact hold generation, confirmation and protected inputs."}
	}
	if err := workflow.LegacyMaintenanceRecovery(args[:2], getenv); err != nil {
		return failure{77, "Legacy recovery is not authorized by the protected workflow."}
	}
	generation, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return err
	}
	inputs, err := os.ReadFile(args[2])
	var config struct {
		Project       string `json:"workload_project_id"`
		Zone          string `json:"database_zone"`
		Management    string `json:"management_project_id"`
		NativeBackups map[string]struct {
			WALArchiving bool `json:"wal_archiving"`
		} `json:"native_backups"`
	}
	if err != nil || string(inputs) != getenv("FOUNDATION_CONFIG") || json.Unmarshal(inputs, &config) != nil ||
		config.Management != getenv("MANAGEMENT_PROJECT_ID") || custody.bucket != getenv("STATE_BUCKET") ||
		!strings.HasPrefix(custody.bucket, config.Management+"-") || !strings.HasSuffix(custody.bucket, "-tofu-state") ||
		config.Project == "" || config.Zone == "" || config.Management == "" ||
		!sequencePattern.MatchString(getenv("GITHUB_RUN_ID")+"-"+getenv("GITHUB_RUN_ATTEMPT")) {
		return failure{65, "Legacy recovery configuration does not match the protected scope."}
	}
	client, err := storage.NewService(custody.ctx, options...)
	if err != nil {
		return err
	}
	object, err := client.Objects.Get(custody.bucket, legacyMaintenanceGuard).Context(custody.ctx).Do()
	if err != nil || object == nil || object.Generation != generation || object.Name != legacyMaintenanceGuard || object.Bucket != custody.bucket {
		return failure{70, "Exact live legacy hold is unavailable; nothing resumed."}
	}
	started, err := time.Parse(time.RFC3339Nano, object.TimeCreated)
	if err != nil {
		return failure{70, "Original maintenance start is unconfirmed."}
	}
	guard := objectReference{Bucket: custody.bucket, Name: legacyMaintenanceGuard, Generation: generation}
	data, err := readObject(custody.ctx, client, guard)
	if err != nil {
		return err
	}
	guard.SHA256 = checksum(data)
	var intent struct {
		SchemaVersion int               `json:"schemaVersion"`
		Kind          string            `json:"kind"`
		Commit        string            `json:"commit"`
		PlanID        string            `json:"planId"`
		PlanSHA256    string            `json:"planSha256"`
		RunID         string            `json:"runId"`
		RunAttempt    string            `json:"runAttempt"`
		Targets       []json.RawMessage `json:"targets"`
	}
	if decodeRecord(data, &intent) != nil || intent.SchemaVersion != 1 || intent.Kind != "legacy-host-maintenance" ||
		!commitPattern.MatchString(intent.Commit) || !digestPattern.MatchString(intent.PlanSHA256) || !sequencePattern.MatchString(intent.PlanID) ||
		!sequencePattern.MatchString(intent.RunID+"-"+intent.RunAttempt) || intent.RunID == getenv("GITHUB_RUN_ID") || len(intent.Targets) < 1 || len(intent.Targets) > 2 {
		return failure{70, "Original legacy maintenance identity is invalid."}
	}
	for _, data := range intent.Targets {
		var target struct{ Project, Zone, Service string }
		if json.Unmarshal(data, &target) != nil || target.Project != config.Project || target.Zone != config.Zone ||
			(target.Service != "json-keys" && target.Service != "authentication") || !config.NativeBackups[target.Service].WALArchiving {
			return failure{70, "Held targets differ from the protected workload scope."}
		}
	}
	// Read the latest attempt: a rerun, including a completed rerun, needs new review.
	var response bytes.Buffer
	if err := custody.execute(custody.ctx, &response, "gh", "api", "--hostname", "github.com", "repos/a-novel/infra/actions/runs/"+intent.RunID,
		"--jq", `{id,run_attempt,status,head_branch,head_sha,event,path,display_title,updated_at,repository:.repository.full_name}`); err != nil {
		return failure{70, "Original maintenance workflow is unreadable."}
	}
	var run struct {
		ID         json.Number `json:"id"`
		Attempt    json.Number `json:"run_attempt"`
		Status     string      `json:"status"`
		Branch     string      `json:"head_branch"`
		Commit     string      `json:"head_sha"`
		Event      string      `json:"event"`
		Path       string      `json:"path"`
		Title      string      `json:"display_title"`
		Updated    string      `json:"updated_at"`
		Repository string      `json:"repository"`
	}
	if decodeRecord(response.Bytes(), &run) != nil || run.ID.String() != intent.RunID || run.Attempt.String() != intent.RunAttempt ||
		run.Status != "completed" || run.Branch != "master" || run.Commit != intent.Commit || run.Event != "workflow_dispatch" ||
		run.Repository != "a-novel/infra" || run.Path != ".github/workflows/foundation.yaml" || !strings.HasPrefix(run.Title, "foundation apply foundation by @") {
		return failure{70, "Original maintenance writer is active, rerun or does not match the hold."}
	}
	finished, err := time.Parse(time.RFC3339Nano, run.Updated)
	if err != nil || !finished.After(started) || finished.After(time.Now()) {
		return failure{70, "Original maintenance completion time is unconfirmed."}
	}
	completionName := fmt.Sprintf("release/legacy-maintenance/completions/%d.json", generation)
	recoveryName := fmt.Sprintf("release/legacy-maintenance/recoveries/%d.json", generation)
	for _, name := range []string{completionName, recoveryName} {
		live, err := liveGeneration(custody.ctx, client, custody.bucket, name)
		if err != nil || live != 0 {
			return failure{70, "Completion or recovery already exists or is unreadable; reconcile it without replay."}
		}
	}
	inputsFile, targetsFile := filepath.Join(custody.scratch, "inputs.json"), filepath.Join(custody.scratch, "targets.json")
	outputsFile, evidenceFile := filepath.Join(custody.scratch, "outputs.json"), filepath.Join(custody.scratch, "evidence.json")
	targets, err := json.Marshal(intent.Targets)
	if err != nil {
		return err
	}
	for path, content := range map[string][]byte{inputsFile: inputs, targetsFile: targets} {
		if err := os.WriteFile(path, content, 0o600); err != nil {
			return err
		}
	}
	for _, action := range []string{"converge", "output"} {
		command := []string{"ALLOW_RESOURCE_DELETION=false", "TOFU_VAR_FILE=" + inputsFile, "./ops/tofu-gate.sh", action, "foundation", custody.bucket}
		if action == "output" {
			command = append(command, outputsFile)
		}
		if err := custody.execute(custody.ctx, io.Discard, "env", command...); err != nil {
			return failure{70, "Foundation convergence or outputs unconfirmed; no host recovery attempted."}
		}
	}
	live, err := liveGeneration(custody.ctx, client, custody.bucket, legacyMaintenanceGuard)
	if err != nil || live != generation {
		return failure{70, "Maintenance hold changed; recovery blocked."}
	}
	attempt, err := json.Marshal(map[string]any{"guard": guard, "runId": getenv("GITHUB_RUN_ID"), "runAttempt": getenv("GITHUB_RUN_ATTEMPT"), "commit": getenv("GITHUB_SHA"), "inputsSha256": checksum(inputs)})
	if err != nil {
		return err
	}
	if _, err := createObject(custody.ctx, client, custody.bucket, recoveryName, attempt); err != nil {
		return failure{70, "Recovery admission uncertain; hold retained. Do not retry."}
	}
	if err := custody.execute(custody.ctx, output, "infra", "database-release", "maintenance-recover", targetsFile, outputsFile, evidenceFile, object.TimeCreated, run.Updated); err != nil {
		return failure{70, "Legacy recovery incomplete; hold and recovery record retained. Do not repeat replacement."}
	}
	if err := custody.document("config", "publish", []string{"foundation", inputsFile, getenv("GITHUB_RUN_ID"), getenv("GITHUB_RUN_ATTEMPT")}, ""); err != nil {
		return failure{70, "Converged configuration publication uncertain; maintenance hold retained."}
	}
	return custody.finishLegacyMaintenance(&legacyMaintenance{client: client, guard: guard, targets: targetsFile}, evidenceFile)
}
