package preflight

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/a-novel/infra/internal/release"
)

// Run verifies a legacy inventory, one service's source images, or its exact job
// secret versions. execute must suppress child diagnostics. Each read is bounded
// and never retried here. Exit codes are 64 for usage, 65 for inputs, 70 for evidence.
func Run(ctx context.Context, args []string, execute func(context.Context, io.Writer, string, ...string) error, stdout, stderr io.Writer) int {
	stop := func(code int, message string) int {
		_, _ = fmt.Fprintln(stderr, message) // Best effort if the diagnostic stream has closed.
		return code
	}
	if len(args) == 0 {
		return stop(64, "Usage: infra preflight images <compiled-release> | service-images <manifest> <tfvars> | service-secrets <tfvars>")
	}
	var images []release.SourceImage
	var inputs serviceInputs
	var err error
	switch {
	case args[0] == "images" && len(args) == 2:
		images, err = release.VerificationImages(args[1], "")
	case args[0] == "service-images" && len(args) == 3:
		inputs, err = readService(args[2])
		if err == nil {
			images, err = release.VerificationImages(args[1], inputs.Service)
		}
		if err == nil {
			err = inputs.bindImages(images)
		}
	case args[0] == "service-secrets" && len(args) == 2:
		inputs, err = readService(args[1])
	default:
		return stop(64, "Invalid preflight arguments.")
	}
	if err != nil {
		return stop(65, "Release prerequisite inputs are invalid; inspect the reviewed manifest and selected configuration.")
	}
	read := func(name string, args ...string) ([]byte, error) {
		ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
		defer cancel()
		var output bytes.Buffer
		err := execute(ctx, &output, name, args...)
		return output.Bytes(), err
	}
	if args[0] == "service-secrets" {
		for _, key := range inputs.secretKeys() {
			state, err := read("gcloud", "secrets", "versions", "describe", strconv.FormatInt(inputs.Secrets[key], 10),
				"--secret=production-"+inputs.Service+"-"+key, "--project="+inputs.Management, "--format=value(state)", "--quiet")
			if err != nil || strings.TrimSpace(string(state)) != "ENABLED" {
				return stop(70, "A selected job secret version is unavailable or not enabled.")
			}
		}
	} else {
		for _, image := range images {
			if err = verifyImage(image, read); err != nil {
				return stop(70, err.Error())
			}
		}
	}
	if _, err = fmt.Fprintln(stdout, "Selected release prerequisites passed."); err != nil {
		return stop(70, "Cannot report prerequisite checks.")
	}
	return 0
}

func verifyImage(image release.SourceImage, read func(string, ...string) ([]byte, error)) error {
	sourceDigest := image.Repository + "@" + image.Digest
	producer := "a-novel/" + image.Component
	if _, err := read("gh", "attestation", "verify", "oci://"+sourceDigest, "--repo", producer,
		"--signer-workflow", producer+"/.github/workflows/release.yaml", "--source-ref", "refs/heads/master", "--deny-self-hosted-runners"); err != nil {
		return errors.New("a release image lacks a valid producer attestation")
	}
	data, err := read("docker", "buildx", "imagetools", "inspect", image.Repository+":"+image.Tag, "--format", "{{json .Manifest}}")
	var manifest struct{ Digest string }
	if err != nil || json.Unmarshal(data, &manifest) != nil || manifest.Digest != image.Digest {
		return errors.New("a release image tag could not be verified against its reviewed digest")
	}
	if image.Slot == "database" {
		data, err = read("docker", "buildx", "imagetools", "inspect", sourceDigest, "--format", "{{json .Image}}")
		var config struct{ Config struct{ Env []string } }
		if err != nil || json.Unmarshal(data, &config) != nil || !slices.Contains(config.Config.Env, "PG_MAJOR=18") {
			return errors.New("a database image does not declare the reviewed PostgreSQL major")
		}
	}
	return nil
}
