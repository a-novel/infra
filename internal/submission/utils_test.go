package submission_test

import (
	"context"
	_ "embed"
	"encoding/json"
	"io"
	"log"
	"mime"
	"mime/multipart"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"cloud.google.com/go/run/apiv2/runpb"
	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	"github.com/google/go-containerregistry/pkg/registry"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/empty"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"go.yaml.in/yaml/v3"
	"google.golang.org/api/storage/v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	"github.com/a-novel/infra/internal/artifact"
)

//go:embed testdata/request.yaml
var requestFixture []byte

const (
	bucket        = "agora-management-test-123456789012-deployment-receipts"
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

func operationFixture(t *testing.T, request *deploypb.CreateReleaseRequest, migration, rotation *runpb.Job) (map[string]any, map[string]string) {
	t.Helper()
	jobs, images := map[string]json.RawMessage{}, map[string]string{}
	for role, native := range map[string]*runpb.Job{"migrations": migration, "rotatekeys": rotation} {
		job := proto.Clone(native).(*runpb.Job)
		job.Name = "projects/123456/locations/europe-west1/jobs/agora-json-keys-" + role
		job.Template.Template.Containers[0].Name = role
		job.Template.Template.Containers[0].Image = strings.Replace(job.Template.Template.Containers[0].Image, "/migrations@", "/"+role+"@", 1)
		jobs[role] = wire(t, &runpb.Job{Name: job.Name, Uid: job.Uid, Template: job.Template})
		images[role] = job.Template.Template.Containers[0].Image
	}
	stateBucket := strings.TrimSuffix(bucket, "-deployment-receipts") + "-tofu-state"
	config := map[string]any{
		"schema_version": 1, "service": "json-keys", "project_id": "agora-json-keys-test", "project_number": "123456",
		"management_project_id": "agora-management-test", "region": "europe-west1", "state_bucket": stateBucket,
		"predecessor": "previous", "rollout_request_id": "33333333-3333-4333-8333-333333333333",
		"request": json.RawMessage(wire(t, request)), "jobs": jobs, "images": images,
		"secret_versions": map[string]int{"postgres-password": 17, "app-master-key": 29},
		"rollout":         map[string]string{"image": request.Release.BuildArtifacts[0].Tag}, "foundation": map[string]any{}, "foundation_json": "{}",
	}
	return config, map[string]string{
		"SERVICE_NATIVE_RELEASE_ENABLED": "true", "GITHUB_EVENT_NAME": "workflow_dispatch",
		"GITHUB_WORKFLOW_REF": "a-novel/infra/.github/workflows/release.yaml@refs/heads/master",
		"GITHUB_SHA":          request.Release.Annotations["source-commit"], "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1",
		"MANAGEMENT_PROJECT_ID": "agora-management-test", "STATE_BUCKET": stateBucket,
		"FOUNDATION_CONFIG": `{"service_projects":{"json-keys":"agora-json-keys-test"},"management_project_id":"agora-management-test","workload_project_id":"agora-production-test","region":"europe-west1"}`,
	}
}

func encodeOperation(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func operationRollout(t *testing.T, release *deploypb.Release) *deploypb.Rollout {
	t.Helper()
	native := &deploypb.Rollout{
		Name: release.Name + "/rollouts/production", Uid: release.Uid + "-rollout", TargetId: "agora-json-keys-grpc",
		Annotations: map[string]string{"request-id": "33333333-3333-4333-8333-333333333333", "release-uid": release.Uid},
		Metadata:    &deploypb.Metadata{CloudRun: &deploypb.CloudRunMetadata{Service: "projects/123456/locations/europe-west1/services/agora-json-keys-grpc", Revision: "agora-json-keys-grpc-" + release.Uid}},
	}
	completeRollout(t, native)
	return native
}

func operationCheckout(t *testing.T, digest string) string {
	t.Helper()
	directory := sourceCheckout(t)
	manifest, err := os.ReadFile("../../tests/fixtures/manifests/valid.yaml")
	if err != nil {
		panic(err)
	}
	manifest = regexp.MustCompile(`sha256:[a-f0-9]{64}`).ReplaceAll(manifest, []byte(digest))
	if err := os.MkdirAll(filepath.Join(directory, "deploy/production"), 0o700); err != nil {
		panic(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "deploy/production/images.yaml"), manifest, 0o600); err != nil {
		panic(err)
	}
	commitSource(t, directory)
	return directory
}

// Exercise the real registry client without outbound network or credential lookup.
// DNS dialing is redirected to the community registry with its trusted test certificate.
func operationRegistry(t *testing.T) (*artifact.Client, string) {
	t.Helper()
	server := httptest.NewTLSServer(registry.New(registry.Logger(log.New(io.Discard, "", 0))))
	t.Cleanup(server.Close)
	transport := server.Client().Transport.(*http.Transport).Clone()
	transport.TLSClientConfig.ServerName = server.Certificate().DNSNames[0]
	transport.DialContext = func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "tcp", server.Listener.Addr().String())
	}
	options := []remote.Option{remote.WithTransport(transport), remote.WithAuth(authn.Anonymous)}
	image, err := mutate.ConfigFile(empty.Image, &v1.ConfigFile{Architecture: "amd64", OS: "linux", Config: v1.Config{Env: []string{"PG_MAJOR=18"}}})
	if err != nil {
		panic(err)
	}
	digest, err := image.Digest()
	if err != nil {
		panic(err)
	}
	for _, registry := range []string{"ghcr.io/a-novel", "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production"} {
		for _, slot := range []string{"database", "grpc", "jobs/migrations", "jobs/rotatekeys"} {
			tag, err := name.NewTag(registry + "/service-json-keys/" + slot + ":v2.5.0")
			if err != nil {
				panic(err)
			}
			if err := remote.Write(tag, image, options...); err != nil {
				panic(err)
			}
		}
	}
	return artifact.NewClient(options...), digest.String()
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
