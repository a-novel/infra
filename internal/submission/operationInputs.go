package submission

import (
	"crypto/sha256"
	"encoding/json"
	jsonv2 "encoding/json/v2"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"cloud.google.com/go/run/apiv2/runpb"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	"github.com/a-novel/infra/internal/workflow"
)

// Native requests and job templates come from the reviewed HCL output. The
// envelope only adds the selectors and predecessor needed by this operation.
type operationInputs struct {
	SchemaVersion    int                        `json:"schema_version"`
	Service          string                     `json:"service"`
	ProjectID        string                     `json:"project_id"`
	ProjectNumber    string                     `json:"project_number"`
	Management       string                     `json:"management_project_id"`
	Region           string                     `json:"region"`
	StateBucket      string                     `json:"state_bucket"`
	Predecessor      string                     `json:"predecessor"`
	RolloutRequestID string                     `json:"rollout_request_id"`
	Request          json.RawMessage            `json:"request"`
	Jobs             map[string]json.RawMessage `json:"jobs"`
	Images           map[string]string          `json:"images"`
	Secrets          map[string]int64           `json:"secret_versions"`
	Rollout          struct {
		Image string `json:"image"`
	} `json:"rollout"`
	Foundation     json.RawMessage `json:"foundation"`
	FoundationJSON string          `json:"foundation_json"`
}

func (input operationInputs) scope() scope {
	return scope{
		input.ProjectID, input.ProjectNumber, input.Region,
		strings.TrimSuffix(input.StateBucket, "-tofu-state") + "-deployment-receipts",
	}
}

func operationConfig(data []byte, getenv func(string) string) (operationInputs, *deploypb.CreateReleaseRequest, error) {
	input, request, err := registeredOperation(data, getenv, getenv("STATE_BUCKET"))
	if err != nil {
		return input, nil, err
	}
	if getenv("SERVICE_NATIVE_RELEASE_ENABLED") != "true" || getenv("GITHUB_EVENT_NAME") != "workflow_dispatch" ||
		getenv("GITHUB_WORKFLOW_REF") != "a-novel/infra/.github/workflows/release.yaml@refs/heads/master" ||
		!numberPattern.MatchString(getenv("GITHUB_RUN_ID")) || !numberPattern.MatchString(getenv("GITHUB_RUN_ATTEMPT")) ||
		request.Release.Annotations["source-commit"] != getenv("GITHUB_SHA") {
		return input, nil, errors.New("service release requires the enabled protected workflow at its exact source commit")
	}
	return input, request, nil
}

// Historical inspection uses current registration without requiring writer activation
// or replacing the recorded source commit with the inspecting workflow's commit.
func registeredOperation(data []byte, getenv func(string) string, bucket string) (operationInputs, *deploypb.CreateReleaseRequest, error) {
	var input operationInputs
	invalid := errors.New("service release requires registered HCL output and an established predecessor")
	if len(data) > maxRequestBytes || jsonv2.Unmarshal(data, &input, jsonv2.RejectUnknownMembers(true)) != nil {
		return input, nil, invalid
	}
	suffix, err := workflow.ServiceScope(data, getenv, bucket)
	if err != nil || suffix != "services/"+input.ProjectID || input.Service != "json-keys" || input.SchemaVersion != 1 {
		return input, nil, invalid
	}
	scope := input.scope()
	if err := scope.validate(); err != nil {
		return input, nil, invalid
	}
	request, err := scope.request(input.Request)
	if err != nil {
		return input, nil, err
	}
	if !releasePattern.MatchString(input.Predecessor) || input.Predecessor == request.ReleaseId {
		return input, nil, invalid
	}
	if !validRequestID(input.RolloutRequestID) || input.RolloutRequestID == request.RequestId {
		return input, nil, invalid
	}
	parameters := request.Release.DeployParameters
	managementNumber := strings.TrimSuffix(strings.TrimPrefix(input.StateBucket, input.Management+"-"), "-tofu-state")
	if parameters["managementProjectNumber"] != managementNumber || input.Rollout.Image != request.Release.BuildArtifacts[0].Tag {
		return input, nil, invalid
	}
	for key, parameter := range map[string]string{"postgres-password": "postgresPasswordVersion", "app-master-key": "masterKeyVersion"} {
		if fmt.Sprint(input.Secrets[key]) != parameters[parameter] {
			return input, nil, invalid
		}
	}
	if len(input.Jobs) != 2 || len(input.Images) != 2 || len(input.Secrets) != 2 || !json.Valid(input.Foundation) || !json.Valid([]byte(input.FoundationJSON)) {
		return input, nil, invalid
	}
	for _, role := range []string{"migrations", "rotatekeys"} {
		job, err := input.job(role)
		if err != nil || job.GetName() != scope.location()+"/jobs/agora-json-keys-"+role || !validRequestID(job.GetUid()) {
			return input, nil, invalid
		}
		allowed := &runpb.Job{Name: job.Name, Uid: job.Uid, Template: job.Template}
		containers := job.GetTemplate().GetTemplate().GetContainers()
		if !proto.Equal(job, allowed) || len(containers) != 1 || containers[0].Image != input.Images[role] {
			return input, nil, invalid
		}
	}
	return input, request, nil
}

func (input operationInputs) job(role string) (*runpb.Job, error) {
	job := &runpb.Job{}
	if protojson.Unmarshal(input.Jobs[role], job) != nil {
		return nil, errors.New("invalid approved native job snapshot")
	}
	return job, nil
}

func prepareOperation(file string, getenv func(string) string, output io.Writer) error {
	data := []byte(getenv("SERVICE_RELEASE_OPERATION_JSON"))
	input, _, err := operationConfig(data, getenv)
	if err != nil {
		return err
	}
	if file == "" || strings.ContainsAny(file, "\r\n") {
		return errors.New("invalid private output path")
	}
	private, err := os.OpenFile(file, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return errors.New("cannot reserve fresh private operation file")
	}
	_, err = private.Write(data)
	if errors.Join(err, private.Close()) != nil {
		return errors.New("cannot save selected private operation")
	}
	managementNumber := strings.TrimSuffix(strings.TrimPrefix(input.StateBucket, input.Management+"-"), "-tofu-state")
	_, err = fmt.Fprintf(output, "file=%s\nsha256=%x\nservice_account=infra-release@%s.iam.gserviceaccount.com\nprovider=projects/%s/locations/global/workloadIdentityPools/github-actions/providers/r-%s\n",
		file, sha256.Sum256(data), input.ProjectID, managementNumber, input.ProjectID)
	return err
}
