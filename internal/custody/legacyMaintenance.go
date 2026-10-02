package custody

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"google.golang.org/api/option"
	"google.golang.org/api/storage/v1"
)

const legacyMaintenanceGuard = "release/legacy-maintenance/operation.json"

type legacyMaintenance struct {
	client  *storage.Service
	guard   objectReference
	targets string
}

func (custody store) checkLegacyMaintenance(options []option.ClientOption) error {
	client, err := storage.NewService(custody.ctx, options...)
	if err != nil {
		return err
	}
	generation, err := liveGeneration(custody.ctx, client, custody.bucket, legacyMaintenanceGuard)
	if err != nil || generation != 0 {
		return failure{70, "Legacy host maintenance is held or unreadable; keep releases paused and reconcile its exact private operation."}
	}
	return nil
}

func (custody store) admitLegacyMaintenance(plan, inputs, commit, planID string, getenv func(string) string, output io.Writer, options []option.ClientOption) (*legacyMaintenance, error) {
	targets := filepath.Join(custody.scratch, "legacy-targets.json")
	if err := custody.execute(custody.ctx, output, "infra", "database-release", "maintenance-plan", plan+".json", inputs, targets); err != nil {
		return nil, failure{70, "Legacy maintenance admission failed; no apply or replacement attempted."}
	}
	data, err := os.ReadFile(targets)
	var selected []json.RawMessage
	if err != nil || json.Unmarshal(data, &selected) != nil {
		return nil, failure{70, "Private maintenance targets are unavailable."}
	}
	if len(selected) == 0 {
		return nil, nil
	}
	if commit != getenv("GITHUB_SHA") || !sequencePattern.MatchString(getenv("GITHUB_RUN_ID")+"-"+getenv("GITHUB_RUN_ATTEMPT")) {
		return nil, failure{65, "Maintenance must identify the exact protected workflow run."}
	}
	planData, err := os.ReadFile(plan)
	if err != nil {
		return nil, err
	}
	client, err := storage.NewService(custody.ctx, options...)
	if err != nil {
		return nil, err
	}
	intent, err := json.Marshal(map[string]any{
		"schemaVersion": 1, "kind": "legacy-host-maintenance", "commit": commit, "planId": planID,
		"planSha256": checksum(planData), "runId": getenv("GITHUB_RUN_ID"), "runAttempt": getenv("GITHUB_RUN_ATTEMPT"), "targets": selected,
	})
	if err != nil {
		return nil, err
	}
	guard, err := createObject(custody.ctx, client, custody.bucket, legacyMaintenanceGuard, intent)
	if err != nil {
		return nil, failure{70, "Maintenance hold was not acknowledged; do not retry or adopt an uncertain operation."}
	}
	if _, err := fmt.Fprintf(output, "Maintenance hold: gs://%s/%s#%d; retain after any interruption.\n", guard.Bucket, guard.Name, guard.Generation); err != nil {
		return nil, err
	}
	return &legacyMaintenance{client, guard, targets}, nil
}

func (custody store) completeLegacyMaintenance(operation *legacyMaintenance, inputs string, output io.Writer) error {
	outputs, evidence := filepath.Join(custody.scratch, "legacy-outputs.json"), filepath.Join(custody.scratch, "legacy-evidence.json")
	if err := custody.execute(custody.ctx, io.Discard, "env", "ALLOW_RESOURCE_DELETION=false", "TOFU_VAR_FILE="+inputs,
		"./ops/tofu-gate.sh", "output", "foundation", custody.bucket, outputs); err != nil {
		return err
	}
	if err := custody.execute(custody.ctx, output, "infra", "database-release", "maintenance-replace", operation.targets, outputs, evidence); err != nil {
		return failure{70, "Maintenance incomplete; hold retained. Keep releases paused, inspect the original run, and do not repeat replacement."}
	}
	return custody.finishLegacyMaintenance(operation, evidence)
}

func (custody store) finishLegacyMaintenance(operation *legacyMaintenance, evidence string) error {
	data, err := os.ReadFile(evidence)
	if err != nil || !json.Valid(data) {
		return failure{70, "Maintenance evidence unavailable; hold retained."}
	}
	completion, err := json.Marshal(map[string]any{"schemaVersion": 1, "outcome": "healthy", "guard": operation.guard, "hosts": json.RawMessage(data)})
	if err != nil {
		return err
	}
	name := fmt.Sprintf("release/legacy-maintenance/completions/%d.json", operation.guard.Generation)
	if _, err := createObject(custody.ctx, operation.client, custody.bucket, name, completion); err != nil {
		return failure{70, "Maintenance completion publication uncertain; hold retained."}
	}
	if err := operation.client.Objects.Delete(custody.bucket, legacyMaintenanceGuard).
		IfGenerationMatch(operation.guard.Generation).Context(custody.ctx).Do(); err != nil {
		return failure{70, "Completion recorded but hold removal uncertain; reconcile the exact generation, never repeat replacement."}
	}
	return nil
}
