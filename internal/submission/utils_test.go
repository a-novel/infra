package submission_test

import (
	_ "embed"
	"encoding/json"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
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
	request := new(deploypb.CreateReleaseRequest)
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

func arguments(t *testing.T, command, input string) []string {
	t.Helper()
	return []string{
		command, "--project-id=agora-json-keys-test", "--project-number=123456",
		"--region=europe-west1", "--receipt-bucket=" + bucket, "--timeout=2s", input,
	}
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
	object := new(storage.Object)
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
