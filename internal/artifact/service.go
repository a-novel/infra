package artifact

import (
	"encoding/json/v2"
	"errors"
	"os"
	"regexp"
	"strings"

	"github.com/a-novel/infra/internal/release"
)

// serviceInputs reads only preflight's native tfvars fields. HCL owns the full
// resource contract; the protected workflow authorizes project/backend ownership.
type serviceInputs struct {
	Service    string            `json:"service"`
	Project    string            `json:"project_id"`
	Management string            `json:"management_project_id"`
	Region     string            `json:"region"`
	Images     map[string]string `json:"images"`
	Secrets    map[string]int64  `json:"secret_versions"`
	Rollout    *struct {
		Image string `json:"image"`
	} `json:"rollout"`
}

func readService(file string) (serviceInputs, error) {
	var inputs serviceInputs
	data, err := os.ReadFile(file)
	if err != nil || json.Unmarshal(data, &inputs) != nil {
		return inputs, errors.New("invalid service inputs")
	}
	project := regexp.MustCompile(`^[a-z][a-z0-9-]{4,28}[a-z0-9]$`)
	if inputs.Service != "json-keys" && inputs.Service != "authentication" {
		return inputs, errors.New("invalid selected service")
	}
	if !project.MatchString(inputs.Project) || !project.MatchString(inputs.Management) || inputs.Project == inputs.Management ||
		!regexp.MustCompile(`^[a-z]+-[a-z]+[1-9][0-9]*$`).MatchString(inputs.Region) {
		return inputs, errors.New("invalid service coordinates")
	}
	secrets := inputs.secretKeys()
	if len(inputs.Secrets) != len(secrets) {
		return inputs, errors.New("invalid job secret inventory")
	}
	for _, key := range secrets {
		if inputs.Secrets[key] < 1 {
			return inputs, errors.New("invalid job secret version")
		}
	}
	return inputs, nil
}

func (inputs serviceInputs) secretKeys() []string {
	keys := []string{"postgres-password"}
	if inputs.Service == "json-keys" {
		keys = append(keys, "app-master-key")
	}
	return keys
}

func (inputs serviceInputs) bindImages(images []release.SourceImage) error {
	roles, api := []string{"migrations"}, "rest"
	if inputs.Service == "json-keys" {
		roles, api = append(roles, "rotatekeys"), "grpc"
	}
	expected := map[string]string{}
	for _, image := range images {
		expected[image.Slot] = inputs.destination(image) + "@" + image.Digest
	}
	invalid := errors.New("job or API image is outside the selected family")
	if len(inputs.Images) != len(roles) {
		return invalid
	}
	for _, role := range roles {
		if inputs.Images[role] != expected["jobs/"+role] {
			return invalid
		}
	}
	if inputs.Rollout != nil && inputs.Rollout.Image != expected[api] {
		return invalid
	}
	return nil
}

func (inputs serviceInputs) destination(image release.SourceImage) string {
	return inputs.Region + "-docker.pkg.dev/" + inputs.Project + "/agora-production/" +
		strings.TrimPrefix(image.Repository, "ghcr.io/a-novel/")
}
