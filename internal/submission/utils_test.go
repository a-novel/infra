package submission_test

import (
	_ "embed"
	"encoding/json"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"go.yaml.in/yaml/v3"
	"google.golang.org/api/storage/v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

//go:embed testdata/request.yaml
var requestFixture []byte

const (
	bucket        = "management-123-deployment-receipts"
	intent        = "services/agora-json-keys-test/production/submissions/release-1.json"
	operationName = "projects/123456/locations/europe-west1/operations/create-1"
)

func fixture(t *testing.T) *deploypb.CreateReleaseRequest {
	t.Helper()
	var document map[string]any
	if err := yaml.Unmarshal(requestFixture, &document); err != nil {
		panic(err)
	}
	data, err := json.Marshal(document)
	if err != nil {
		panic(err)
	}
	request := &deploypb.CreateReleaseRequest{}
	if err := protojson.Unmarshal(data, request); err != nil {
		panic(err)
	}
	return request
}

func wire(t *testing.T, message proto.Message) []byte {
	t.Helper()
	data, err := protojson.Marshal(message)
	if err != nil {
		panic(err)
	}
	return data
}

func arguments(t *testing.T, command, input string, sourceDirectories ...string) []string {
	t.Helper()
	args := []string{
		command, "--project-id=agora-json-keys-test", "--project-number=123456",
		"--region=europe-west1", "--receipt-bucket=" + bucket, "--timeout=5s",
	}
	for _, directory := range sourceDirectories {
		args = append(args, "--source-dir="+directory)
	}
	return append(args, input)
}

func upload(t *testing.T, request *http.Request) (*storage.Object, []byte) {
	t.Helper()
	_, params, err := mime.ParseMediaType(request.Header.Get("Content-Type"))
	if err != nil {
		panic(err)
	}
	reader := multipart.NewReader(request.Body, params["boundary"])
	metadata, err := reader.NextPart()
	if err != nil {
		panic(err)
	}
	object := &storage.Object{}
	if err := json.NewDecoder(metadata).Decode(object); err != nil {
		panic(err)
	}
	media, err := reader.NextPart()
	if err != nil {
		panic(err)
	}
	data, err := io.ReadAll(media)
	if err != nil {
		panic(err)
	}
	return object, data
}

func sourceCheckout(t *testing.T) string {
	t.Helper()
	directory := t.TempDir()
	path := filepath.Join(directory, "deploy/cloud-deploy/json-keys")
	if err := os.MkdirAll(path, 0o700); err != nil {
		panic(err)
	}
	for _, name := range []string{"skaffold.yaml", "service.yaml"} {
		data, err := os.ReadFile(filepath.Join("../../deploy/cloud-deploy/json-keys", name))
		if err != nil {
			panic(err)
		}
		if err := os.WriteFile(filepath.Join(path, name), data, 0o644); err != nil {
			panic(err)
		}
	}
	gitSource(t, directory, "init", "--quiet")
	commitSource(t, directory)
	return directory
}

func gitSource(t *testing.T, directory string, args ...string) string {
	t.Helper()
	command := exec.CommandContext(t.Context(), "git", append([]string{
		"-C", directory, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
		"-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
	}, args...)...)
	data, err := command.Output()
	if err != nil {
		panic(err)
	}
	return strings.TrimSpace(string(data))
}

func commitSource(t *testing.T, directory string) {
	t.Helper()
	gitSource(t, directory, "add", ".")
	gitSource(t, directory, "commit", "--quiet", "-m", "test fixture")
}

func bindSource(t *testing.T, request *deploypb.CreateReleaseRequest, directory string) string {
	t.Helper()
	commit := gitSource(t, directory, "rev-parse", "HEAD")
	request.Release.Annotations["source-commit"] = commit
	name := "services/agora-json-keys-test/production/sources/" + commit + ".tar.gz"
	request.Release.SkaffoldConfigUri = "gs://" + bucket + "/" + name
	return name
}

func completeRollout(t *testing.T, value *deploypb.Rollout) {
	t.Helper()
	value.ApprovalState, value.State = deploypb.Rollout_APPROVED, deploypb.Rollout_SUCCEEDED
	for _, id := range []string{"canary-0", "stable"} {
		value.Phases = append(value.Phases, &deploypb.Phase{
			Id: id, State: deploypb.Phase_SUCCEEDED,
			Jobs: &deploypb.Phase_DeploymentJobs{DeploymentJobs: &deploypb.DeploymentJobs{
				DeployJob: &deploypb.Job{State: deploypb.Job_SUCCEEDED},
				VerifyJob: &deploypb.Job{State: deploypb.Job_SUCCEEDED},
			}},
		})
	}
}
