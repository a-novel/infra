package custody

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"google.golang.org/api/googleapi"
	"google.golang.org/api/option"
	"google.golang.org/api/storage/v1"
)

type applyIntent struct {
	SchemaVersion int    `json:"schemaVersion"`
	Root          string `json:"root"`
	Project       string `json:"project_id"`
	Service       string `json:"service"`
	Region        string `json:"region"`
	Commit        string `json:"commit"`
	RunID         string `json:"runId"`
	RunAttempt    string `json:"runAttempt"`
	PlanID        string `json:"planId"`
	PlanSHA256    string `json:"planSha256"`
	InputsSHA256  string `json:"inputsSha256"`
}

type objectReference struct {
	Bucket     string `json:"bucket"`
	Name       string `json:"object"`
	Generation int64  `json:"generation,string"`
	SHA256     string `json:"sha256"`
}

// The acknowledged generation stays in this process. There is deliberately no
// constructor that adopts a persisted guard or unlocks an interrupted operation.
type serviceOperation struct {
	client *storage.Service
	intent applyIntent
	guard  objectReference
}

func (custody store) admit(args []string, inputs []byte, plan string, getenv func(string) string, output io.Writer, options []option.ClientOption) (*serviceOperation, error) {
	intent := applyIntent{}
	var fields map[string]json.RawMessage
	if json.Unmarshal(inputs, &fields) != nil {
		return nil, failure{65, "Invalid service apply inputs."}
	}
	// Match the case-sensitive fields already authorized against registration.
	for name, target := range map[string]*string{"project_id": &intent.Project, "service": &intent.Service, "region": &intent.Region} {
		if json.Unmarshal(fields[name], target) != nil {
			return nil, failure{65, "Invalid service apply scope."}
		}
	}
	data, err := os.ReadFile(plan)
	if err != nil {
		return nil, err
	}
	intent.SchemaVersion, intent.Root, intent.Commit, intent.PlanID = 1, args[0], args[1], args[2]
	intent.RunID, intent.RunAttempt = getenv("GITHUB_RUN_ID"), getenv("GITHUB_RUN_ATTEMPT")
	intent.PlanSHA256, intent.InputsSHA256 = checksum(data), checksum(inputs)
	client, err := storage.NewService(custody.ctx, options...)
	if err != nil {
		return nil, failure{70, "Service admission client unavailable; no apply attempted."}
	}
	name := "services/" + intent.Project + "/release/operation.json"
	if _, err := fmt.Fprintf(output, "Service guard: gs://%s/%s; reconcile this object after any interrupted apply.\n", custody.bucket, name); err != nil {
		return nil, err
	}
	encoded, err := json.Marshal(intent)
	if err != nil {
		return nil, err
	}
	guard, err := createObject(custody.ctx, client, custody.bucket, name, encoded)
	if err != nil {
		return nil, failure{70, "Service admission was not acknowledged; an existing or uncertain guard blocks apply. Do not retry or adopt it."}
	}
	return &serviceOperation{client: client, intent: intent, guard: guard}, nil
}

func (operation serviceOperation) finish(ctx context.Context, inputs []byte) error {
	intent := operation.intent
	name, err := sequenceName(intent.RunID+"-"+intent.RunAttempt, ".tfvars.json")
	if err != nil {
		return err
	}
	prefix := "foundation/services/" + intent.Project + "/config/"
	if intent.Root == "service-release" {
		prefix = "services/" + intent.Project + "/release/config/"
	}
	config, err := createObject(ctx, operation.client, operation.guard.Bucket, prefix+name, inputs)
	if err != nil {
		return failure{70, "Converged configuration publication unconfirmed; service guard retained."}
	}
	completion := struct {
		SchemaVersion int             `json:"schemaVersion"`
		Outcome       string          `json:"outcome"`
		Operation     applyIntent     `json:"operation"`
		Guard         objectReference `json:"guard"`
		Configuration objectReference `json:"configuration"`
	}{1, "converged", intent, operation.guard, config}
	encoded, err := json.Marshal(completion)
	if err != nil {
		return err
	}
	receipts := strings.TrimSuffix(operation.guard.Bucket, "-tofu-state") + "-deployment-receipts"
	name = fmt.Sprintf("services/%s/production/operations/%d.json", intent.Project, operation.guard.Generation)
	if _, err := createObject(ctx, operation.client, receipts, name, encoded); err != nil {
		return failure{70, "Apply completion evidence unconfirmed; service guard retained."}
	}
	// Match the live generation, never delete a successor or an archived state object.
	err = operation.client.Objects.Delete(operation.guard.Bucket, operation.guard.Name).
		IfGenerationMatch(operation.guard.Generation).Context(ctx).Do()
	if err != nil {
		return failure{70, "Completion recorded but guard removal unconfirmed; reconcile its exact generation, do not repeat apply."}
	}
	return nil
}

func createObject(ctx context.Context, client *storage.Service, bucket, name string, data []byte) (objectReference, error) {
	object, err := client.Objects.Insert(bucket, &storage.Object{Name: name}).
		Media(bytes.NewReader(data), googleapi.ContentType("application/json"), googleapi.ChunkSize(0)).
		IfGenerationMatch(0).Context(ctx).Do()
	if err != nil || object == nil || object.Name != name || object.Bucket != bucket || object.Generation <= 0 {
		return objectReference{}, failure{70, "Private object creation was not acknowledged."}
	}
	return objectReference{bucket, name, object.Generation, checksum(data)}, nil
}

func checksum(data []byte) string { return fmt.Sprintf("%x", sha256.Sum256(data)) }
