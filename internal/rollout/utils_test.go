package rollout_test

import (
	_ "embed"
	"encoding/json"
	"testing"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"cloud.google.com/go/run/apiv2/runpb"
	"go.yaml.in/yaml/v3"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	"github.com/a-novel/infra/internal/rollout"
)

//go:embed testdata/candidate.yaml
var candidate []byte

func fixture(t *testing.T) (rollout.Config, rollout.Snapshot, *runpb.Job) {
	t.Helper()
	var documents map[string]any
	if err := yaml.Unmarshal(candidate, &documents); err != nil {
		panic(err)
	}
	state := rollout.Snapshot{Release: &deploypb.Release{}, Rollout: &deploypb.Rollout{}, JobRun: &deploypb.JobRun{}, Service: &runpb.Service{}, Revision: &runpb.Revision{}}
	job := &runpb.Job{}
	for name, message := range map[string]proto.Message{"release": state.Release, "rollout": state.Rollout, "jobRun": state.JobRun, "service": state.Service, "revision": state.Revision, "job": job} {
		data, err := json.Marshal(documents[name])
		if err != nil {
			panic(err)
		}
		if err := protojson.Unmarshal(data, message); err != nil {
			panic(err)
		}
	}
	return rollout.Config{
		ProjectID: "agora-json-keys-test", ProjectNumber: "123456", Region: "europe-west1", Service: "agora-json-keys-grpc",
		Release: "release-1", Rollout: "rollout-1", JobRun: "verify-1", Revision: "agora-json-keys-grpc-new", Phase: "canary-0",
		ProbeAccount: job.Template.Template.ServiceAccount, VerifierImage: job.Template.Template.Containers[0].Image,
		ProbeNetwork: job.Template.Template.VpcAccess.NetworkInterfaces[0].Network,
		ProbeSubnet:  job.Template.Template.VpcAccess.NetworkInterfaces[0].Subnetwork,
	}, state, job
}
