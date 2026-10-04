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

	"github.com/a-novel/infra/internal/workflow"
)

type applyIntent struct {
	SchemaVersion int    `json:"schemaVersion"`
	Root          string `json:"root"`
	Project       string `json:"project_id"`
	SourceProject string `json:"source_project,omitempty"`
	Scope         string `json:"scope,omitempty"`
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

type applyCompletion struct {
	SchemaVersion int              `json:"schemaVersion"`
	Outcome       string           `json:"outcome"`
	Operation     applyIntent      `json:"operation"`
	Guard         objectReference  `json:"guard"`
	Configuration objectReference  `json:"configuration"`
	State         *objectReference `json:"state,omitempty"`
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
	if args[0] == "service-recovery" {
		host, err := workflow.RecoveryScope(inputs, getenv, custody.bucket)
		if err != nil {
			return nil, failure{65, "Invalid native recovery apply scope."}
		}
		intent.Project, intent.SourceProject = host.Project, host.SourceProject
		intent.Service, intent.Region = "json-keys", host.Region
	} else {
		// Match the case-sensitive fields already authorized against registration.
		for name, target := range map[string]*string{"project_id": &intent.Project, "service": &intent.Service, "region": &intent.Region} {
			if json.Unmarshal(fields[name], target) != nil {
				return nil, failure{65, "Invalid service apply scope."}
			}
		}
	}
	data, err := os.ReadFile(plan)
	if err != nil {
		return nil, err
	}
	intent.SchemaVersion, intent.Root, intent.Commit, intent.PlanID = 1, args[0], args[1], args[2]
	if (args[0] == "service-foundation" || args[0] == "service-release") && foundationScopePattern.MatchString(getenv("TOFU_STATE_SUFFIX")) {
		intent.SchemaVersion, intent.Scope = 2, getenv("TOFU_STATE_SUFFIX")
	}
	intent.RunID, intent.RunAttempt = getenv("GITHUB_RUN_ID"), getenv("GITHUB_RUN_ATTEMPT")
	intent.PlanSHA256, intent.InputsSHA256 = checksum(data), checksum(inputs)
	client, err := storage.NewService(custody.ctx, options...)
	if err != nil {
		return nil, failure{70, "Service admission client unavailable; no apply attempted."}
	}
	name := intent.guardName()
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
	if _, err := fmt.Fprintf(output, "Acknowledged service guard generation: %d\n", guard.Generation); err != nil {
		return nil, err
	}
	if intent.Root == "service-recovery" {
		name := "foundation/recovery/services/" + intent.Project + "/restore-attempt.json"
		used, err := liveGeneration(custody.ctx, client, custody.bucket, name)
		if err != nil || used != 0 {
			return nil, failure{70, "Recovery destination was already used or its reservation is unreadable; apply blocked and guard retained."}
		}
	}
	return &serviceOperation{client: client, intent: intent, guard: guard}, nil
}

func (operation serviceOperation) finish(ctx context.Context, inputs []byte) error {
	intent := operation.intent
	name, err := intent.configurationName()
	if err != nil {
		return err
	}
	config, err := createObject(ctx, operation.client, operation.guard.Bucket, name, inputs)
	if err != nil {
		return failure{70, "Converged configuration publication unconfirmed; service guard retained."}
	}
	completion := applyCompletion{SchemaVersion: 1, Outcome: intent.outcome(), Operation: intent, Guard: operation.guard, Configuration: config}
	if intent.Root == "service-recovery" {
		name := "foundation/recovery/services/" + intent.Project + "/default.tfstate"
		generation, err := liveGeneration(ctx, operation.client, operation.guard.Bucket, name)
		if err != nil || generation == 0 {
			return failure{70, "Prepared recovery state is unavailable; guard retained."}
		}
		state := objectReference{Bucket: operation.guard.Bucket, Name: name, Generation: generation}
		data, err := readObject(ctx, operation.client, state)
		if err != nil {
			return err
		}
		state.SHA256 = checksum(data)
		completion.State = &state
	}
	encoded, err := json.Marshal(completion)
	if err != nil {
		return err
	}
	receipts := strings.TrimSuffix(operation.guard.Bucket, "-tofu-state") + "-deployment-receipts"
	name = intent.completionName(operation.guard.Generation)
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

func (intent applyIntent) configurationName() (string, error) {
	name, err := sequenceName(intent.RunID+"-"+intent.RunAttempt, ".tfvars.json")
	if err != nil {
		return "", err
	}
	switch intent.Root {
	case "service-foundation":
		if intent.Scope != "" {
			return "foundation/" + intent.Scope + "/config/" + name, nil
		}
		return "foundation/services/" + intent.Project + "/config/" + name, nil
	case "service-release":
		if intent.Scope != "" {
			return intent.Scope + "/release/config/" + name, nil
		}
		return "services/" + intent.Project + "/release/config/" + name, nil
	case "service-recovery":
		if intent.SourceProject == "" || intent.SourceProject == intent.Project ||
			!strings.HasPrefix(intent.Project, "a-novel-recovery-") || !serviceScopePattern.MatchString("services/"+intent.Project) {
			return "", failure{65, "Invalid recovery destination."}
		}
		return "foundation/recovery/services/" + intent.Project + "/config/" + name, nil
	default:
		return "", failure{65, "Invalid service apply root."}
	}
}

func (intent applyIntent) guardProject() string {
	if intent.Root == "service-recovery" {
		return intent.SourceProject
	}
	return intent.Project
}

func (intent applyIntent) operationScope() string {
	if intent.Scope != "" {
		return "workloads/production/" + intent.Service
	}
	return intent.guardProject()
}

func (intent applyIntent) guardName() string {
	if intent.Scope != "" {
		return "foundation/operations/production/" + intent.Service + "/operation.json"
	}
	return "services/" + intent.guardProject() + "/release/operation.json"
}

func (intent applyIntent) completionName(generation int64) string {
	scope := intent.Scope
	if scope == "" {
		scope = "services/" + intent.guardProject()
	}
	return fmt.Sprintf("%s/production/operations/%d.json", scope, generation)
}

func (intent applyIntent) outcome() string {
	if intent.Root == "service-recovery" {
		return "host-prepared"
	}
	return "converged"
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
