package custody

import (
	"encoding/json"
	"io"
	"reflect"
	"slices"
	"strconv"
	"strings"

	"google.golang.org/api/cloudscheduler/v1"
	"google.golang.org/api/option"
	runv1 "google.golang.org/api/run/v1"
	cloudrun "google.golang.org/api/run/v2"
)

// releaseChecks observes native operations; it never starts or retries a job.
// The reviewed apply owns execution through Cloud Run's run_execution_token.
func (storage store) releaseChecks(data []byte, operation *serviceOperation, before bool, options []option.ClientOption) error {
	if operation == nil || operation.intent.Root != "service-release" {
		return nil
	}
	var config struct {
		Zone      string `json:"zone"`
		Private   string `json:"private_project_id"`
		Migration string `json:"migration_image"`
		API       *struct {
			Image    string `json:"image"`
			Revision string `json:"revision"`
			Serving  string `json:"serving_revision"`
		} `json:"api"`
	}
	if json.Unmarshal(data, &config) != nil {
		return failure{65, "Invalid native release inputs."}
	}
	if config.Migration == "" {
		return nil // Definition-only bootstrap remains a separate, explicitly selected path.
	}
	intent := operation.intent
	client, err := cloudrun.NewService(storage.ctx, options...)
	if err != nil {
		return failure{70, "Native release observation unavailable; guard retained."}
	}
	project := intent.Project
	if config.Zone == "public-api" {
		project = config.Private
	}
	location := "projects/" + project + "/locations/" + intent.Region
	if before && intent.Service == "json-keys" {
		scheduler, err := cloudscheduler.NewService(storage.ctx, options...)
		if err != nil {
			return failure{70, "Rotation schedule observation unavailable; guard retained."}
		}
		job, err := scheduler.Projects.Locations.Jobs.Get(location + "/jobs/agora-json-keys-rotation").Context(storage.ctx).Do()
		if err != nil || job.State != "PAUSED" {
			return failure{70, "Pause the existing key-rotation schedule before release; guard retained and no apply attempted."}
		}
		err = client.Projects.Locations.Jobs.Executions.List(location+"/jobs/agora-json-keys-rotatekeys").Pages(storage.ctx,
			func(page *cloudrun.GoogleCloudRunV2ListExecutionsResponse) error {
				for _, execution := range page.Executions {
					if execution.CompletionTime == "" || execution.Reconciling || execution.RunningCount != 0 {
						return failure{70, "Key rotation is still active or uncertain; guard retained and no apply attempted."}
					}
				}
				return nil
			})
		if err != nil {
			return failure{70, "Key rotation is not confirmed idle; guard retained and no apply attempted."}
		}
	}
	if before && config.API != nil && config.API.Revision == config.API.Serving {
		// A promotion may change traffic only. The prior guarded completion proves
		// that this exact candidate configuration passed its post-apply checks.
		uri, err := storage.latest("gs://"+storage.bucket+"/"+intent.Scope+"/release/config", ".tfvars.json")
		if err != nil {
			return failure{70, "Prior converged release unavailable; promotion blocked and guard retained."}
		}
		prior, err := storage.download(uri)
		if err != nil {
			return err
		}
		var previous, proposed map[string]any
		if json.Unmarshal(prior, &previous) != nil || json.Unmarshal(data, &proposed) != nil {
			return failure{70, "Prior release unreadable; promotion blocked and guard retained."}
		}
		api, ok := previous["api"].(map[string]any)
		if !ok {
			return failure{70, "An existing checked candidate is required before promotion."}
		}
		if api["serving_revision"] != config.API.Serving {
			api["serving_revision"] = config.API.Serving
			if previous["migration_image"] == nil || !reflect.DeepEqual(previous, proposed) {
				return failure{70, "Promotion must use the exact checked candidate and change only serving_revision; guard retained."}
			}
		}
	}
	if !before || config.Zone == "public-api" {
		proof, err := storage.completedReleaseJob(client, location+"/jobs/agora-"+intent.Service+"-migrations", config.Migration, checksum([]byte(config.Migration))[:24], options)
		if err != nil {
			return err
		}
		if !before {
			operation.checks = append(operation.checks, proof)
		}
	}
	if before || config.API == nil {
		return nil
	}
	role := "rest"
	if config.Zone == "private" {
		role = "grpc"
	}
	name := "projects/" + intent.Project + "/locations/" + intent.Region + "/services/agora-" + intent.Service + "-" + role
	api, err := client.Projects.Locations.Services.Get(name).Context(storage.ctx).Do()
	if err != nil || api.Reconciling || api.DeleteTime != "" || api.Generation <= 0 || api.ObservedGeneration != api.Generation ||
		api.TerminalCondition == nil || api.TerminalCondition.State != "CONDITION_SUCCEEDED" || api.Template == nil ||
		api.Template.Revision != config.API.Revision || len(api.Template.Containers) != 1 || api.Template.Containers[0].Image != config.API.Image {
		return failure{70, "Exact API revision is not confirmed ready; guard retained."}
	}
	candidate, serving, total := false, false, int64(0)
	for _, traffic := range api.TrafficStatuses {
		total += traffic.Percent
		candidate = candidate || (traffic.Tag == "candidate" && traffic.Revision == config.API.Revision)
		serving = serving || (traffic.Revision == config.API.Serving && traffic.Percent == 100)
	}
	if !candidate || !serving || total != 100 {
		return failure{70, "Exact candidate and serving traffic are unconfirmed; guard retained."}
	}
	if config.Zone == "private" {
		// OpenTofu jsonencode sorts these keys; the same token identifies the native probe.
		value, err := json.Marshal(map[string]string{"image": config.API.Image, "revision": config.API.Revision, "serving_revision": config.API.Serving})
		if err != nil {
			return err
		}
		proof, err := storage.completedReleaseJob(client, location+"/jobs/agora-json-keys-smoke", config.API.Image, checksum(value)[:24], options)
		if err != nil {
			return err
		}
		operation.checks = append(operation.checks, proof)
	} else {
		if intent.Service != "authentication" {
			return failure{65, "Only the enrolled Authentication public API supports routine releases."}
		}
		url := strings.Replace(api.Uri, "https://", "https://candidate---", 1)
		if config.API.Revision == config.API.Serving {
			url = api.Uri
		}
		if err := storage.execute(storage.ctx, io.Discard, "infra", "check-health", "candidate", url); err != nil {
			return failure{70, "API dependency health failed; guard retained, traffic not automatically rolled back."}
		}
	}
	operation.checks = append(operation.checks, api.Name+"/revisions/"+config.API.Revision)
	return nil
}

// completedReleaseJob binds the token-named immutable execution to its native job UID and generation.
func (storage store) completedReleaseJob(client *cloudrun.Service, name, image, token string, options []option.ClientOption) (string, error) {
	invalid := failure{70, "Exact native release execution is unavailable, changed or unsuccessful; guard retained. Never replay an uncertain migration."}
	job, err := client.Projects.Locations.Jobs.Get(name).Context(storage.ctx).Do()
	if err != nil || job.Name != name || job.Reconciling || job.DeleteTime != "" || job.Uid == "" || job.Generation <= 0 || job.ObservedGeneration != job.Generation ||
		job.RunExecutionToken != token || job.TerminalCondition == nil || job.TerminalCondition.State != "CONDITION_SUCCEEDED" ||
		job.Template == nil || job.Template.Template == nil || len(job.Template.Template.Containers) != 1 || job.Template.Template.Containers[0].Image != image {
		return "", invalid
	}
	_, short, ok := strings.Cut(job.Name, "/jobs/")
	if !ok || short == "" || strings.Contains(short, "/") {
		return "", invalid
	}
	executionName := job.Name + "/executions/" + short + "-" + token
	parts := strings.Split(job.Name, "/")
	if len(parts) != 6 {
		return "", invalid
	}
	// v1 exposes Google's job UID/generation labels, which v2 strips. This native
	// binding survives platform image resolution and execution network normalization.
	observer, err := runv1.NewService(storage.ctx, append([]option.ClientOption{option.WithEndpoint("https://" + parts[3] + "-run.googleapis.com/")}, options...)...)
	if err != nil {
		return "", invalid
	}
	execution, err := observer.Namespaces.Executions.Get("namespaces/" + parts[1] + "/executions/" + short + "-" + token).Context(storage.ctx).Do()
	if err != nil || execution.Metadata == nil || execution.Spec == nil || execution.Status == nil {
		return "", invalid
	}
	metadata, spec, status := execution.Metadata, execution.Spec, execution.Status
	if metadata.Name != short+"-"+token || metadata.Uid == "" || metadata.DeletionTimestamp != "" || metadata.Generation <= 0 || status.ObservedGeneration != metadata.Generation ||
		metadata.Labels["run.googleapis.com/job"] != short || metadata.Labels["run.googleapis.com/jobUid"] != job.Uid ||
		metadata.Labels["run.googleapis.com/jobGeneration"] != strconv.FormatInt(job.Generation, 10) ||
		status.CompletionTime == "" || spec.TaskCount != 1 || spec.Parallelism != 1 || status.SucceededCount != 1 ||
		status.FailedCount != 0 || status.CancelledCount != 0 || status.RunningCount != 0 || status.RetriedCount != 0 ||
		!slices.ContainsFunc(status.Conditions, func(c *runv1.GoogleCloudRunV1Condition) bool {
			return c.Type == "Completed" && c.Status == "True"
		}) {
		return "", invalid
	}
	return executionName + "#" + metadata.Uid, nil
}
