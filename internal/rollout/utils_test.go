package rollout_test

import (
	_ "embed"
	"encoding/json"
	"strings"
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
	return scopedFixture(t, "agora-json-keys-grpc", "")
}

func scopedFixture(t *testing.T, service, zone string) (rollout.Config, rollout.Snapshot, *runpb.Job) {
	t.Helper()
	data := string(candidate)
	if zone != "" {
		workload := "json-keys"
		if service == "agora-authentication-rest" {
			workload = "authentication"
		}
		protocol, suffix := "grpc", zone
		if zone == "public-api" {
			protocol, suffix = "rest", "api"
		}
		data = strings.NewReplacer(
			"agora-json-keys-grpc", service,
			"agora-production/verify", "agora-"+workload+"-"+suffix+"-tooling/verify",
			"agora-production/service-json-keys/grpc", "agora-"+workload+"-"+suffix+"-production/service-"+workload+"/"+protocol,
			"image: service-json-keys", "image: service-"+workload,
			"rollout-probe@", "probe-"+workload+"-"+suffix+"@",
		).Replace(data)
	}
	var documents map[string]any
	if err := yaml.Unmarshal([]byte(data), &documents); err != nil {
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
	if zone == "public-api" {
		state.Service.Ingress = runpb.IngressTraffic_INGRESS_TRAFFIC_ALL
		state.Service.InvokerIamDisabled = true
	}
	return rollout.Config{
		ProjectID: "agora-json-keys-test", ProjectNumber: "123456", Region: "europe-west1", Service: service, Zone: zone,
		Release: "release-1", Rollout: "rollout-1", JobRun: "verify-1", Revision: service + "-new", Phase: "canary-0",
		ProbeAccount: job.Template.Template.ServiceAccount, VerifierImage: job.Template.Template.Containers[0].Image,
		ProbeNetwork: job.Template.Template.VpcAccess.NetworkInterfaces[0].Network,
		ProbeSubnet:  job.Template.Template.VpcAccess.NetworkInterfaces[0].Subnetwork,
	}, state, job
}

func completeRollout(t *testing.T, value *deploypb.Rollout) {
	t.Helper()
	value.State, value.ApprovalState = deploypb.Rollout_SUCCEEDED, deploypb.Rollout_APPROVED
	for _, name := range []string{"canary-0", "stable"} {
		value.Phases = append(value.Phases, &deploypb.Phase{
			Id: name, State: deploypb.Phase_SUCCEEDED,
			Jobs: &deploypb.Phase_DeploymentJobs{DeploymentJobs: &deploypb.DeploymentJobs{
				DeployJob: &deploypb.Job{Id: "deploy", State: deploypb.Job_SUCCEEDED, JobType: &deploypb.Job_DeployJob{DeployJob: &deploypb.DeployJob{}}},
				VerifyJob: &deploypb.Job{Id: "verify", State: deploypb.Job_SUCCEEDED, JobType: &deploypb.Job_VerifyJob{VerifyJob: &deploypb.VerifyJob{}}},
			}},
		})
	}
}

func verificationEnv(t *testing.T, config rollout.Config) map[string]string {
	t.Helper()
	return map[string]string{
		"EXPECTED_PROJECT_ID": config.ProjectID, "CLOUD_DEPLOY_PROJECT_ID": config.ProjectID, "CLOUD_RUN_PROJECT": config.ProjectID,
		"CLOUD_DEPLOY_PROJECT": config.ProjectNumber, "EXPECTED_REGION": config.Region,
		"CLOUD_RUN_LOCATION": config.Region, "CLOUD_DEPLOY_LOCATION": config.Region,
		"EXPECTED_SERVICE": config.Service, "CLOUD_RUN_SERVICE": config.Service, "EXPECTED_ZONE": config.Zone,
		"CLOUD_DEPLOY_TARGET": config.Service, "CLOUD_DEPLOY_DELIVERY_PIPELINE": config.Service,
		"CLOUD_DEPLOY_RELEASE": config.Release, "CLOUD_DEPLOY_ROLLOUT": config.Rollout,
		"CLOUD_DEPLOY_JOB_RUN": config.JobRun, "CLOUD_RUN_REVISION": config.Revision, "CLOUD_DEPLOY_PHASE": config.Phase,
		"EXPECTED_PROBE_ACCOUNT": config.ProbeAccount, "EXPECTED_VERIFIER_IMAGE": config.VerifierImage,
		"EXPECTED_PROBE_NETWORK": config.ProbeNetwork, "EXPECTED_PROBE_SUBNET": config.ProbeSubnet,
	}
}
