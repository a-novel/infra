package rollout

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
)

var (
	idPattern      = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,62}$`)
	projectPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{4,28}[a-z0-9]$`)
	regionPattern  = regexp.MustCompile(`^[a-z]+-[a-z]+[1-9][0-9]*$`)
	numberPattern  = regexp.MustCompile(`^[1-9][0-9]*$`)
	digestPattern  = regexp.MustCompile(`^[a-z0-9/-]+@sha256:[a-f0-9]{64}$`)
)

// Config binds one verification to the fixed target and platform-provided job run.
type Config struct {
	ProjectID, ProjectNumber, Region, Service string
	Release, Rollout, JobRun, Revision, Phase string
	ProbeAccount, VerifierImage               string
	ProbeNetwork, ProbeSubnet                 string
}

// FromEnv rejects scope mismatches before opening authenticated clients.
func FromEnv(env func(string) string) (Config, error) {
	config := Config{
		ProjectID: env("EXPECTED_PROJECT_ID"), ProjectNumber: env("CLOUD_DEPLOY_PROJECT"),
		Region: env("EXPECTED_REGION"), Service: env("EXPECTED_SERVICE"),
		Release: env("CLOUD_DEPLOY_RELEASE"), Rollout: env("CLOUD_DEPLOY_ROLLOUT"),
		JobRun: env("CLOUD_DEPLOY_JOB_RUN"), Revision: env("CLOUD_RUN_REVISION"), Phase: env("CLOUD_DEPLOY_PHASE"),
		ProbeAccount: env("EXPECTED_PROBE_ACCOUNT"), VerifierImage: env("EXPECTED_VERIFIER_IMAGE"),
		ProbeNetwork: env("EXPECTED_PROBE_NETWORK"), ProbeSubnet: env("EXPECTED_PROBE_SUBNET"),
	}
	if !projectPattern.MatchString(config.ProjectID) || !numberPattern.MatchString(config.ProjectNumber) ||
		!regionPattern.MatchString(config.Region) || config.Service != "agora-json-keys-grpc" ||
		env("CLOUD_DEPLOY_PROJECT_ID") != config.ProjectID ||
		(env("CLOUD_RUN_PROJECT") != config.ProjectID && env("CLOUD_RUN_PROJECT") != config.ProjectNumber) ||
		env("CLOUD_RUN_LOCATION") != config.Region || env("CLOUD_DEPLOY_LOCATION") != config.Region ||
		env("CLOUD_RUN_SERVICE") != config.Service || env("CLOUD_DEPLOY_TARGET") != config.Service ||
		env("CLOUD_DEPLOY_DELIVERY_PIPELINE") != config.Service ||
		(config.Phase != "canary-0" && config.Phase != "stable") {
		return Config{}, errors.New("verification target or phase mismatch")
	}
	for _, id := range []string{config.Release, config.Rollout, config.JobRun, config.Revision} {
		if !idPattern.MatchString(id) {
			return Config{}, errors.New("invalid verification identity")
		}
	}
	account := regexp.MustCompile(`^[a-z][a-z0-9-]{4,28}[a-z0-9]@` + regexp.QuoteMeta(config.ProjectID) + `\.iam\.gserviceaccount\.com$`)
	if !account.MatchString(config.ProbeAccount) || !config.image(config.VerifierImage, "") ||
		!strings.HasPrefix(config.ProbeNetwork, "projects/"+config.ProjectID+"/global/networks/") ||
		!strings.HasPrefix(config.ProbeSubnet, "projects/"+config.ProjectID+"/regions/"+config.Region+"/subnetworks/") {
		return Config{}, errors.New("invalid probe identity or verifier digest")
	}
	return config, nil
}

func (config Config) location() string {
	return fmt.Sprintf("projects/%s/locations/%s", config.ProjectNumber, config.Region)
}

func (config Config) serviceName() string { return config.location() + "/services/" + config.Service }

func (config Config) revisionName() string {
	return config.serviceName() + "/revisions/" + config.Revision
}

func (config Config) probeName() string {
	return config.location() + "/jobs/" + config.Service + "-verify"
}

func (config Config) releaseName() string {
	return config.location() + "/deliveryPipelines/" + config.Service + "/releases/" + config.Release
}

func (config Config) rolloutName() string {
	return config.releaseName() + "/rollouts/" + config.Rollout
}

func (config Config) jobRunName() string { return config.rolloutName() + "/jobRuns/" + config.JobRun }

func (config Config) image(image, repositoryPath string) bool {
	prefix := config.Region + "-docker.pkg.dev/" + config.ProjectID + "/"
	if repositoryPath != "" {
		prefix += "agora-production/" + repositoryPath
	}
	return len(image) > len(prefix) && image[:len(prefix)] == prefix && digestPattern.MatchString(image[len(config.Region+"-docker.pkg.dev/"):])
}
