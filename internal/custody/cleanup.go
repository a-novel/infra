package custody

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	resourcemanager "google.golang.org/api/cloudresourcemanager/v3"
	"google.golang.org/api/option"
	"google.golang.org/api/storage/v1"

	"github.com/a-novel/infra/internal/recovery"
	"github.com/a-novel/infra/internal/workflow"
)

type cleanupIntent struct {
	SchemaVersion int             `json:"schemaVersion"`
	Kind          string          `json:"kind"`
	Target        projectDeletion `json:"target"`
	Restore       objectReference `json:"restore"`
	Commit        string          `json:"commit"`
	RunID         string          `json:"runId"`
	RunAttempt    string          `json:"runAttempt"`
}

type cleanupCompletion struct {
	Outcome   string          `json:"outcome"`
	Operation cleanupIntent   `json:"operation"`
	Guard     objectReference `json:"guard"`
}

func (custody store) cleanup(args []string, getenv func(string) string, output io.Writer, options []option.ClientOption) error {
	if len(args) != 3 {
		return failure{64, "Usage: infra custody recovery cleanup <state-bucket> <inputs-file> <authorization> <confirmation>"}
	}
	if !workflow.RecoveryCleanupEnabled(getenv) || getenv("RECOVERY_OPERATION") != "cleanup-native" {
		return failure{77, "Native cleanup is not activated in the protected recovery workflow."}
	}
	inputs, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	host, err := workflow.RecoveryScope(inputs, getenv, custody.bucket)
	if err != nil || args[2] != "DELETE "+host.Project {
		return failure{65, "Native cleanup scope or typed confirmation differs."}
	}
	var authorization struct {
		SchemaVersion int    `json:"schemaVersion"`
		Project       string `json:"replacementProject"`
		Number        string `json:"projectNumber"`
		Service       string `json:"service"`
		Source        string `json:"sourceProject"`
		Generation    string `json:"restoreGeneration"`
		Revoked       bool   `json:"crossProjectAccessRevoked"`
	}
	data, err := os.ReadFile(args[1])
	if err != nil || decodeRecord(data, &authorization) != nil {
		return failure{65, "Invalid committed cleanup authorization."}
	}
	generation, err := strconv.ParseInt(authorization.Generation, 10, 64)
	if err != nil || generation <= 0 || strconv.FormatInt(generation, 10) != authorization.Generation || !projectNumberPattern.MatchString(authorization.Number) {
		return failure{77, "Committed cleanup requires exact numeric project and restore identities."}
	}
	if authorization.SchemaVersion != 1 || !authorization.Revoked {
		return failure{77, "Committed cleanup must attest revoked cross-project access."}
	}
	if authorization.Project != host.Project || authorization.Service != "json-keys" || authorization.Source != host.SourceProject {
		return failure{77, "Committed cleanup does not match the registered destination and source service."}
	}
	if _, err := cleanupBoundary(host.Project, getenv); err != nil {
		return err
	}
	if err := custody.cleanupLabel(getenv); err != nil {
		return err
	}
	intent := cleanupIntent{
		SchemaVersion: 1, Kind: "native-cleanup", Target: projectDeletion{host.Project, authorization.Number},
		Commit: getenv("GITHUB_SHA"), RunID: getenv("GITHUB_RUN_ID"), RunAttempt: getenv("GITHUB_RUN_ATTEMPT"),
	}
	if !sequencePattern.MatchString(intent.RunID + "-" + intent.RunAttempt) {
		return failure{65, "Invalid cleanup workflow identity."}
	}
	ctx, cancel := context.WithTimeout(custody.ctx, 3*time.Minute)
	defer cancel()
	client, err := storage.NewService(ctx, options...)
	if err != nil {
		return err
	}
	expected := applyIntent{Project: host.SourceProject, Service: "json-keys", Region: host.Region}
	restored, err := readOperation(ctx, client, custody.bucket, expected, generation, getenv)
	if err != nil {
		return err
	}
	if restored.restore == nil || !restored.completed || restored.live != 0 || restored.restore.Target.Request != host.Request() {
		return failure{70, "Cleanup requires completed, exported recovery evidence and no live service operation."}
	}
	if err := custody.completedWriter(ctx, restored); err != nil {
		return err
	}
	intent.Restore = restored.guard
	preparation, _, err := preparedTarget(ctx, client, custody.bucket, host.SourceProject, restored.restore.Preparation)
	if err != nil || preparation.Operation.InputsSHA256 != checksum(inputs) {
		return failure{65, "Cleanup inputs differ from the exact prepared host."}
	}
	encoded, err := json.Marshal(intent)
	if err != nil {
		return err
	}
	guard, err := createObject(ctx, client, custody.bucket, restored.guard.Name, encoded)
	if err != nil {
		return failure{70, "Cleanup admission unconfirmed; do not retry or adopt an existing guard."}
	}
	if _, err := fmt.Fprintf(output, "Native cleanup guard: %s; generation %d. Never replay deletion; reconcile this generation.\n", host.SourceProject, guard.Generation); err != nil {
		return err
	}
	live, err := liveGeneration(ctx, client, preparation.State.Bucket, preparation.State.Name)
	if err != nil || live != preparation.State.Generation {
		return failure{70, "Prepared state changed; cleanup blocked and guard retained."}
	}
	runtime := recovery.Host{Target: restored.restore.Target, DiskGiB: host.DiskGiB, Image: host.RestoreImage, Execute: custody.execute}
	if err := runtime.CheckStopped(ctx); err != nil {
		return failure{70, "Exact prepared host is not confirmed stopped; cleanup blocked and guard retained."}
	}
	projects, err := resourcemanager.NewService(ctx, options...)
	if err != nil {
		return err
	}
	if err := intent.Target.authorize(ctx, projects, host.ManagementProject); err != nil {
		return err
	}
	// Permanent reservation survives a lost API response and successful guard release.
	if _, err := createObject(ctx, client, custody.bucket, intent.attemptName(), encoded); err != nil {
		return failure{70, "Cleanup reservation unconfirmed or already used; guard retained. Never replay."}
	}
	if err := intent.Target.dispatch(ctx, projects); err != nil {
		return err
	}
	if err := intent.record(ctx, client, guard); err != nil {
		return err
	}
	if err := client.Objects.Delete(guard.Bucket, guard.Name).IfGenerationMatch(guard.Generation).Context(ctx).Do(); err != nil {
		return failure{70, "Deletion-requested recorded; guard removal unconfirmed. Finish only this generation."}
	}
	_, err = fmt.Fprintln(output, "deletion-requested: evidence and reservations retained. Permanent erasure and final billing are not confirmed.")
	return err
}

func (intent cleanupIntent) attemptName() string {
	return "foundation/recovery/services/" + intent.Target.Project + "/cleanup-attempt.json"
}

func (intent cleanupIntent) record(ctx context.Context, client *storage.Service, guard objectReference) error {
	data, err := json.Marshal(cleanupCompletion{"deletion-requested", intent, guard})
	if err != nil {
		return err
	}
	source := strings.TrimSuffix(strings.TrimPrefix(guard.Name, "services/"), "/release/operation.json")
	receipts := strings.TrimSuffix(guard.Bucket, "-tofu-state") + "-deployment-receipts"
	if _, err := createObject(ctx, client, receipts, completionName(source, guard.Generation), data); err != nil {
		return failure{70, "Cleanup completion publication unconfirmed; guard retained. Reconcile without deletion replay."}
	}
	return nil
}

func inspectCleanup(ctx context.Context, client *storage.Service, expected applyIntent, guard objectReference, data []byte) (*cleanupIntent, bool, error) {
	var intent cleanupIntent
	if err := decodeRecord(data, &intent); err != nil {
		return nil, false, err
	}
	invalid := failure{70, "Cleanup evidence does not match the exact completed recovery; guard retained."}
	if intent.SchemaVersion != 1 || intent.Kind != "native-cleanup" || !projectNumberPattern.MatchString(intent.Target.Number) {
		return nil, false, invalid
	}
	if !commitPattern.MatchString(intent.Commit) || !sequencePattern.MatchString(intent.RunID+"-"+intent.RunAttempt) {
		return nil, false, invalid
	}
	if intent.Restore.Bucket != guard.Bucket || intent.Restore.Name != guard.Name || !digestPattern.MatchString(intent.Restore.SHA256) {
		return nil, false, invalid
	}
	if intent.Restore.Generation <= 0 || intent.Restore.Generation == guard.Generation {
		return nil, false, invalid
	}
	data, err := readObject(ctx, client, intent.Restore)
	if err != nil || checksum(data) != intent.Restore.SHA256 {
		return nil, false, invalid
	}
	restored, completed, err := inspectRestore(ctx, client, expected, intent.Restore, data)
	if err != nil || !completed || restored.Target.Project != intent.Target.Project {
		return nil, false, invalid
	}
	data, err = readCurrentObject(ctx, client, guard.Bucket, intent.attemptName())
	var reserved cleanupIntent
	if err != nil || decodeRecord(data, &reserved) != nil || reserved != intent {
		return nil, false, failure{70, "Cleanup dispatch reservation absent or different; retain guard for manual reconciliation."}
	}
	data, err = readCurrentObject(ctx, client, strings.TrimSuffix(guard.Bucket, "-tofu-state")+"-deployment-receipts", completionName(expected.Project, guard.Generation))
	if err != nil || data == nil {
		return &intent, false, err
	}
	var receipt cleanupCompletion
	if decodeRecord(data, &receipt) != nil || receipt != (cleanupCompletion{"deletion-requested", intent, guard}) {
		return nil, false, invalid
	}
	return &intent, true, nil
}

func (intent cleanupIntent) reconcile(ctx context.Context, client *storage.Service, guard objectReference, options []option.ClientOption) error {
	projects, err := resourcemanager.NewService(ctx, options...)
	if err != nil {
		return err
	}
	// Read only: ACTIVE, missing or inaccessible projects never authorize a replay.
	if err := intent.Target.check(ctx, projects, "DELETE_REQUESTED"); err != nil {
		return err
	}
	return intent.record(ctx, client, guard)
}
