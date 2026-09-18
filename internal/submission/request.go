// Package submission persists render-only Cloud Deploy intent before dispatch.
// Recovery reads the exact identity; it never resends a request or starts a rollout.
package submission

import (
	"errors"
	"fmt"
	"net/netip"
	"regexp"
	"strings"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

const maxRequestBytes = 64 << 10

var (
	projectPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{4,28}[a-z0-9]$`)
	numberPattern  = regexp.MustCompile(`^[1-9][0-9]*$`)
	regionPattern  = regexp.MustCompile(`^[a-z]+-[a-z]+[1-9][0-9]*$`)
	bucketPattern  = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$`)
	releasePattern = regexp.MustCompile(`^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$`)
	uuidPattern    = regexp.MustCompile(`^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)
	commitPattern  = regexp.MustCompile(`^[a-f0-9]{40}$`)
	digestPattern  = regexp.MustCompile(`^[a-f0-9]{64}$`)
	versionPattern = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)
	networkPattern = regexp.MustCompile(`^projects/([a-z][a-z0-9-]{4,28}[a-z0-9])/global/networks/[a-z]([a-z0-9-]{0,61}[a-z0-9])?$`)
)

// scope is supplied separately from the request by the trusted caller. Syntax checks
// do not establish that a project number, bucket or foundation input is authorized.
type scope struct {
	ProjectID, ProjectNumber, Region, ReceiptBucket string
}

func (scope scope) validate() error {
	for _, field := range []struct {
		value   string
		pattern *regexp.Regexp
	}{
		{scope.ProjectID, projectPattern},
		{scope.ProjectNumber, numberPattern},
		{scope.Region, regionPattern},
		{scope.ReceiptBucket, bucketPattern},
	} {
		if !field.pattern.MatchString(field.value) {
			return errors.New("invalid independently selected project, region or receipt bucket")
		}
	}
	return nil
}

func (scope scope) location() string {
	return fmt.Sprintf("projects/%s/locations/%s", scope.ProjectNumber, scope.Region)
}

func (scope scope) parent() string {
	return scope.location() + "/deliveryPipelines/agora-json-keys-grpc"
}

func (scope scope) prefix() string { return "services/" + scope.ProjectID + "/production/" }

func (scope scope) intentName(id string) string {
	return scope.prefix() + "submissions/" + id + ".json"
}

func (scope scope) request(data []byte) (*deploypb.CreateReleaseRequest, error) {
	request := new(deploypb.CreateReleaseRequest)
	if len(data) > maxRequestBytes || protojson.Unmarshal(data, request) != nil {
		return nil, errors.New("expected a bounded native CreateReleaseRequest JSON document")
	}
	if request.Parent != scope.parent() || !releasePattern.MatchString(request.ReleaseId) {
		return nil, errors.New("release must belong to the selected JSON Keys pipeline")
	}
	if !uuidPattern.MatchString(request.RequestId) || request.RequestId == "00000000-0000-0000-0000-000000000000" {
		return nil, errors.New("requestId must be a nonzero lowercase UUID")
	}
	release := request.GetRelease()
	allowed := &deploypb.CreateReleaseRequest{
		Parent: request.Parent, ReleaseId: request.ReleaseId, RequestId: request.RequestId,
		Release: submittedFields(release),
	}
	if !proto.Equal(request, allowed) {
		return nil, errors.New("request contains unsupported fields or policy overrides")
	}
	if release.GetName() != scope.parent()+"/releases/"+request.ReleaseId {
		return nil, errors.New("release name does not match its reserved identity")
	}
	annotations := release.GetAnnotations()
	if len(annotations) != 2 || annotations["request-id"] != request.RequestId || !commitPattern.MatchString(annotations["source-commit"]) {
		return nil, errors.New("release annotations must bind the request UUID and exact source commit")
	}
	source := "gs://" + scope.ReceiptBucket + "/" + scope.prefix() + "sources/" + annotations["source-commit"] + ".tar.gz"
	if release.SkaffoldConfigUri != source || release.SkaffoldConfigPath != "skaffold.yaml" || !versionPattern.MatchString(release.SkaffoldVersion) {
		return nil, errors.New("release must use its commit-addressed source archive and a pinned Skaffold version")
	}
	artifacts := release.BuildArtifacts
	imagePrefix := scope.Region + "-docker.pkg.dev/" + scope.ProjectID + "/agora-production/service-json-keys/grpc@sha256:"
	if len(artifacts) != 1 || artifacts[0].GetImage() != "service-json-keys" || !strings.HasPrefix(artifacts[0].GetTag(), imagePrefix) {
		return nil, errors.New("release must contain only the selected project's JSON Keys gRPC image")
	}
	if !digestPattern.MatchString(strings.TrimPrefix(artifacts[0].Tag, imagePrefix)) {
		return nil, errors.New("release image must be pinned by digest")
	}
	if err := scope.parameters(release.DeployParameters); err != nil {
		return nil, err
	}
	return request, nil
}

func (scope scope) parameters(parameters map[string]string) error {
	network := networkPattern.FindStringSubmatch(parameters["network"])
	if len(network) == 0 {
		return errors.New("invalid foundation network")
	}
	ip, err := netip.ParseAddr(parameters["databasePrivateIP"])
	if err != nil || !ip.Is4() || !ip.IsPrivate() {
		return errors.New("database address must be private IPv4")
	}
	patterns := map[string]string{
		"projectId":               regexp.QuoteMeta(scope.ProjectID),
		"network":                 regexp.QuoteMeta(parameters["network"]),
		"subnetwork":              `projects/` + regexp.QuoteMeta(network[1]) + `/regions/` + regexp.QuoteMeta(scope.Region) + `/subnetworks/[a-z]([a-z0-9-]{0,61}[a-z0-9])?`,
		"runtimeServiceAccount":   `[a-z][a-z0-9-]{4,28}[a-z0-9]@` + regexp.QuoteMeta(scope.ProjectID) + `\.iam\.gserviceaccount\.com`,
		"databasePrivateIP":       regexp.QuoteMeta(ip.String()),
		"managementProjectNumber": `[1-9][0-9]*`,
		"masterKeyVersion":        `[1-9][0-9]*`,
		"postgresPasswordVersion": `[1-9][0-9]*`,
	}
	if len(parameters) != len(patterns) {
		return errors.New("release requires exactly the eight JSON Keys deploy parameters")
	}
	for name, pattern := range patterns {
		if !regexp.MustCompile("^" + pattern + "$").MatchString(parameters[name]) {
			return fmt.Errorf("invalid JSON Keys deploy parameter: %s", name)
		}
	}
	return nil
}

// Compare only caller-owned fields: Google adds timestamps, snapshots and render
// results. The same projection rejects those output fields in a submitted request.
func submittedFields(release *deploypb.Release) *deploypb.Release {
	if release == nil {
		return nil
	}
	return &deploypb.Release{
		Name: release.Name, Annotations: release.Annotations, BuildArtifacts: release.BuildArtifacts,
		SkaffoldConfigUri: release.SkaffoldConfigUri, SkaffoldConfigPath: release.SkaffoldConfigPath,
		SkaffoldVersion: release.SkaffoldVersion, DeployParameters: release.DeployParameters,
	}
}
