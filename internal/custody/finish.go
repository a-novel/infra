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

// finishApply repeats only the last storage deletion of a recorded converged apply.
// Incomplete operations have no recovery path here, even if their workflow ended.
func (custody store) finishApply(ctx context.Context, client *storage.Service, evidence applyEvidence, root string, output io.Writer) error {
	if !evidence.completed || evidence.intent.Root != root {
		return failure{70, "Only exact recorded convergence can finish; incomplete or different applies remain blocked."}
	}
	guard := evidence.guard
	if evidence.live != 0 && evidence.live != guard.Generation {
		return failure{70, "Another guard generation is live; it cannot be finished by this operation."}
	}
	if err := custody.completedWriter(ctx, evidence.intent); err != nil {
		return err
	}
	if evidence.live == 0 {
		_, err := fmt.Fprintln(output, "Recorded apply verified; its guard is already absent. No mutation performed.")
		return err
	}
	// A delayed delete must never affect a successor or remove a retained version.
	if err := client.Objects.Delete(guard.Bucket, guard.Name).IfGenerationMatch(guard.Generation).Context(ctx).Do(); err != nil {
		return failure{70, "Guard removal unconfirmed; inspect this exact generation before any further action."}
	}
	_, err := fmt.Fprintf(output, "Finished recorded %s apply for %s; removed live guard generation %d. No resources reapplied.\n", root, evidence.intent.Service, guard.Generation)
	return err
}

func (custody store) completedWriter(ctx context.Context, intent applyIntent) error {
	var output bytes.Buffer
	endpoint := "repos/a-novel/infra/actions/runs/" + intent.RunID + "/attempts/" + intent.RunAttempt
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
	if decodeRecord(output.Bytes(), &run) != nil || run.ID.String() != intent.RunID || run.Attempt.String() != intent.RunAttempt {
		return failure{70, "Original workflow attempt identity could not be verified; guard retained."}
	}
	if run.Status != "completed" || run.Branch != "master" || run.Commit != intent.Commit || run.Event != "workflow_dispatch" {
		return failure{70, "Original workflow attempt is active or differs from the recorded apply; guard retained."}
	}
	prefix := "foundation apply " + intent.Root + "/" + intent.Service + " by @"
	if run.Repository != "a-novel/infra" || run.Path != ".github/workflows/foundation.yaml" || !strings.HasPrefix(run.Title, prefix) {
		return failure{70, "Original workflow does not identify the selected protected apply; guard retained."}
	}
	return nil
}
