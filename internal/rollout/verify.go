package rollout

import (
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"time"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"cloud.google.com/go/run/apiv2/runpb"
)

// Snapshot is the provider-owned state inspected before and after a probe.
type Snapshot struct {
	Release  *deploypb.Release
	Rollout  *deploypb.Rollout
	JobRun   *deploypb.JobRun
	Service  *runpb.Service
	Revision *runpb.Revision
}

// Check requires the exact image and phase traffic, returning the endpoint to probe.
func (config Config) Check(snapshot Snapshot) (Probe, error) {
	release, rollout, jobRun := snapshot.Release, snapshot.Rollout, snapshot.JobRun
	metadata := rollout.GetMetadata().GetCloudRun()
	if release.GetName() != config.releaseName() || release.GetRenderState() != deploypb.Release_SUCCEEDED ||
		rollout.GetName() != config.rolloutName() || rollout.GetTargetId() != config.Service ||
		rollout.GetState() != deploypb.Rollout_IN_PROGRESS ||
		metadata.GetService() != config.serviceName() || metadata.GetRevision() != config.Revision ||
		jobRun.GetName() != config.jobRunName() || jobRun.GetPhaseId() != config.Phase ||
		jobRun.GetState() != deploypb.JobRun_IN_PROGRESS || jobRun.GetVerifyJobRun() == nil {
		return Probe{}, errors.New("release, rollout or verification job identity mismatch")
	}
	artifacts := release.GetBuildArtifacts()
	if len(artifacts) != 1 || artifacts[0].GetImage() != "service-json-keys" ||
		!config.image(artifacts[0].GetTag(), "service-json-keys/grpc@sha256:") {
		return Probe{}, errors.New("release must select one promoted JSON Keys API digest")
	}
	service, revision := snapshot.Service, snapshot.Revision
	if service.GetName() != config.serviceName() || service.GetReconciling() || service.GetDeleteTime() != nil ||
		service.GetObservedGeneration() != service.GetGeneration() ||
		service.GetTerminalCondition().GetState() != runpb.Condition_CONDITION_SUCCEEDED ||
		service.GetIngress() != runpb.IngressTraffic_INGRESS_TRAFFIC_INTERNAL_ONLY || service.GetInvokerIamDisabled() ||
		revision.GetName() != config.revisionName() || revision.GetService() != config.serviceName() ||
		revision.GetReconciling() || revision.GetDeleteTime() != nil ||
		!slices.ContainsFunc(revision.GetConditions(), func(condition *runpb.Condition) bool {
			return condition.GetType() == "Ready" && condition.GetState() == runpb.Condition_CONDITION_SUCCEEDED
		}) || len(revision.GetContainers()) != 1 || revision.GetContainers()[0].GetImage() != artifacts[0].GetTag() {
		return Probe{}, errors.New("private service revision is not ready at the release digest")
	}
	probe := Probe{Audience: service.GetUri(), Phase: config.Phase, Revision: config.revisionName(), Image: artifacts[0].GetTag(), JobRun: config.jobRunName()}
	tag := "candidate"
	if config.Phase == "stable" {
		tag = "stable"
	}
	var total, selected int32
	var matches int
	for _, traffic := range service.GetTrafficStatuses() {
		if traffic.GetPercent() < 0 || traffic.GetPercent() > 100 {
			return Probe{}, errors.New("invalid traffic allocation")
		}
		total += traffic.GetPercent()
		if traffic.GetRevision() == config.Revision {
			selected += traffic.GetPercent()
		}
		if traffic.GetTag() == tag {
			matches++
			if traffic.GetRevision() != config.Revision {
				return Probe{}, errors.New("phase tag identifies another revision")
			}
			probe.URL = traffic.GetUri()
		}
	}
	if matches != 1 || total != 100 || (config.Phase == "canary-0" && selected != 0) || (config.Phase == "stable" && selected != 100) {
		return Probe{}, errors.New("actual traffic does not match the verification phase")
	}
	if config.Phase == "stable" {
		probe.URL = service.GetUri()
	}
	return probe, probe.Validate()
}

// CheckJob accepts only the reviewed, secret-free probe before requesting execution.
func (config Config) CheckJob(job *runpb.Job) error {
	if job.GetName() != config.probeName() || job.GetEtag() == "" || job.GetReconciling() || job.GetDeleteTime() != nil ||
		job.GetTemplate().GetTaskCount() != 1 || job.GetTemplate().GetParallelism() != 1 {
		return errors.New("probe job is missing or not converged")
	}
	return config.checkTemplate(job.GetTemplate().GetTemplate(), "")
}

// CheckExecution accepts only the completed execution returned by this invocation.
func (config Config) CheckExecution(execution *runpb.Execution, request string) error {
	if !strings.HasPrefix(execution.GetName(), config.probeName()+"/executions/") || execution.GetJob() != config.probeName() ||
		execution.GetCompletionTime() == nil || execution.GetReconciling() || execution.GetTaskCount() != 1 ||
		execution.GetSucceededCount() != 1 || execution.GetFailedCount() != 0 || execution.GetCancelledCount() != 0 ||
		execution.GetRunningCount() != 0 || execution.GetRetriedCount() != 0 {
		return errors.New("probe execution did not complete exactly once successfully")
	}
	return config.checkTemplate(execution.GetTemplate(), request)
}

func (config Config) checkTemplate(template *runpb.TaskTemplate, request string) error {
	containers := template.GetContainers()
	interfaces := template.GetVpcAccess().GetNetworkInterfaces()
	if template.GetServiceAccount() != config.ProbeAccount || template.GetMaxRetries() != 0 ||
		template.GetTimeout().AsDuration() != 90*time.Second || len(template.GetVolumes()) != 0 ||
		template.GetVpcAccess().GetEgress() != runpb.VpcAccess_ALL_TRAFFIC || len(containers) != 1 ||
		len(interfaces) != 1 || interfaces[0].GetNetwork() != config.ProbeNetwork || interfaces[0].GetSubnetwork() != config.ProbeSubnet ||
		!slices.Equal(interfaces[0].GetTags(), []string{"agora-rollout-probe"}) {
		return errors.New("probe runtime boundary mismatch")
	}
	container := containers[0]
	if container.GetName() != "probe" || container.GetImage() != config.VerifierImage || len(container.GetCommand()) != 0 ||
		!slices.Equal(container.GetArgs(), []string{"probe"}) || len(container.GetVolumeMounts()) != 0 {
		return errors.New("probe container differs from the reviewed verifier")
	}
	env := container.GetEnv()
	if request == "" && len(env) == 0 {
		return nil
	}
	if request != "" && len(env) == 1 && env[0].GetName() == "VERIFY_REQUEST" && env[0].GetValueSource() == nil && env[0].GetValue() == request {
		return nil
	}
	return errors.New("probe execution inputs differ from the requested verification")
}

func (probe Probe) encode() (string, error) {
	data, err := json.Marshal(probe)
	return string(data), err
}
