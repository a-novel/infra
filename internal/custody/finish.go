package custody

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"google.golang.org/api/storage/v1"
)

// finishOperation repeats only the last guard deletion of a recorded successful operation.
// Incomplete operations have no recovery path here, even if their workflow ended.
func (custody store) finishOperation(ctx context.Context, client *storage.Service, evidence operationEvidence, output io.Writer) error {
	if !evidence.completed {
		return failure{70, "Only exact recorded completion can finish; incomplete operations remain blocked."}
	}
	guard := evidence.guard
	if evidence.live != 0 && evidence.live != guard.Generation {
		return failure{70, "Another guard generation is live; it cannot be finished by this operation."}
	}
	if err := custody.completedWriter(ctx, evidence); err != nil {
		return err
	}
	if evidence.live == 0 {
		_, err := fmt.Fprintln(output, "Recorded completion verified; its guard is already absent. No mutation performed.")
		return err
	}
	// A delayed delete must never affect a successor or remove a retained version.
	if err := client.Objects.Delete(guard.Bucket, guard.Name).IfGenerationMatch(guard.Generation).Context(ctx).Do(); err != nil {
		return failure{70, "Guard removal unconfirmed; inspect this exact generation before any further action."}
	}
	_, err := fmt.Fprintf(output, "Finished recorded operation for %s; removed live guard generation %d. No deployment work repeated.\n", evidence.intent.Service, guard.Generation)
	return err
}

func (custody store) completedWriter(ctx context.Context, evidence operationEvidence) error {
	intent := evidence.intent
	runID, attempt, commit := intent.RunID, intent.RunAttempt, intent.Commit
	path, prefix := ".github/workflows/foundation.yaml", "foundation apply "+intent.Root+"/"+intent.Service+" by @"
	if native := evidence.native; native != nil {
		runID, attempt, commit = native.RunID, native.RunAttempt, native.Commit
		path, prefix = ".github/workflows/release.yaml", "production deploy-service by @"
	}
	var output bytes.Buffer
	endpoint := "repos/a-novel/infra/actions/runs/" + runID + "/attempts/" + attempt
	query := `{id,run_attempt,status,head_branch,head_sha,event,path,display_title,repository:.repository.full_name}`
	if err := custody.execute(ctx, &output, "gh", "api", "--hostname", "github.com", endpoint, "--jq", query); err != nil {
		return failure{70, "Original workflow attempt unavailable; guard retained."}
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
		Repository string      `json:"repository"`
	}
	if decodeRecord(output.Bytes(), &run) != nil || run.ID.String() != runID || run.Attempt.String() != attempt {
		return failure{70, "Original workflow attempt identity could not be verified; guard retained."}
	}
	if run.Status != "completed" || run.Branch != "master" || run.Commit != commit || run.Event != "workflow_dispatch" {
		return failure{70, "Original workflow attempt is active or differs from the recorded operation; guard retained."}
	}
	if run.Repository != "a-novel/infra" || run.Path != path || !strings.HasPrefix(run.Title, prefix) {
		return failure{70, "Original workflow does not identify the selected protected operation; guard retained."}
	}
	return nil
}
