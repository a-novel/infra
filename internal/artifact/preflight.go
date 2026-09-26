package artifact

import (
	"context"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/a-novel/infra/internal/release"
)

// Run verifies a legacy inventory, one service's source images, or its exact job
// secret versions. execute must suppress child diagnostics. Each read is bounded
// and never retried here. Exit codes are 64 for usage, 65 for inputs, 70 for evidence.
func Run(ctx context.Context, args []string, execute func(context.Context, io.Writer, string, ...string) error, registry Registry, stdout, stderr io.Writer) int {
	stop := func(code int, message string) int {
		_, _ = fmt.Fprintln(stderr, message) // Best effort if the diagnostic stream has closed.
		return code
	}
	if len(args) == 0 {
		return stop(64, "Usage: infra preflight resolve-images <manifest> <output> | images <compiled-release> | service-images <manifest> <tfvars> | service-secrets <tfvars>")
	}
	var images []release.SourceImage
	var inputs serviceInputs
	var err error
	switch {
	case args[0] == "resolve-images" && len(args) == 3:
		err = release.ResolveManifest(args[1], args[2], func(image release.SourceImage) (string, error) {
			if err := resolveImage(ctx, &image, registry); err != nil {
				return "", err
			}
			return image.Digest, verifyImage(ctx, image, execute, registry)
		})
		if err != nil {
			return stop(70, err.Error())
		}
	case args[0] == "images" && len(args) == 2:
		images, err = release.VerificationImages(args[1], "")
	case args[0] == "service-images" && len(args) == 3:
		inputs, err = readService(args[2])
		if err == nil {
			images, err = release.VerificationImages(args[1], inputs.Service)
		}
		if err == nil {
			err = resolveImages(ctx, images, registry)
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
	if args[0] == "service-secrets" {
		if err := inputs.verifySecrets(ctx, execute); err != nil {
			return stop(70, err.Error())
		}
	} else {
		for _, image := range images {
			if err = verifyImage(ctx, image, execute, registry); err != nil {
				return stop(70, err.Error())
			}
		}
	}
	if _, err = fmt.Fprintln(stdout, "Selected release prerequisites passed."); err != nil {
		return stop(70, "Cannot report prerequisite checks.")
	}
	return 0
}

func resolveImages(ctx context.Context, images []release.SourceImage, registry Registry) error {
	for index := range images {
		if err := resolveImage(ctx, &images[index], registry); err != nil {
			return err
		}
	}
	return nil
}

func resolveImage(ctx context.Context, image *release.SourceImage, registry Registry) error {
	if image.Digest != "" {
		return nil
	}
	digest, err := registry.Resolve(ctx, image.Repository+":"+image.Tag)
	if err != nil {
		return err
	}
	if !regexp.MustCompile(`^sha256:[a-f0-9]{64}$`).MatchString(digest) {
		return errors.New("invalid resolved image digest")
	}
	image.Digest = digest
	return nil
}

// VerifyServiceSecrets checks enabled versions from the already-bound input bytes,
// avoiding a second read of a mutable local file during a guarded operation.
func VerifyServiceSecrets(ctx context.Context, data []byte, execute func(context.Context, io.Writer, string, ...string) error) error {
	inputs, err := parseService(data)
	if err != nil {
		return err
	}
	return inputs.verifySecrets(ctx, execute)
}

func (inputs serviceInputs) verifySecrets(ctx context.Context, execute func(context.Context, io.Writer, string, ...string) error) error {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	for _, key := range inputs.secretKeys() {
		var state strings.Builder
		err := execute(ctx, &state, "gcloud", "secrets", "versions", "describe", strconv.FormatInt(inputs.Secrets[key], 10),
			"--secret=production-"+inputs.Service+"-"+key, "--project="+inputs.Management, "--format=value(state)", "--quiet")
		if err != nil || strings.TrimSpace(state.String()) != "ENABLED" {
			return errors.New("a selected job secret version is unavailable or not enabled")
		}
	}
	return nil
}

func verifyImage(ctx context.Context, image release.SourceImage, execute func(context.Context, io.Writer, string, ...string) error, registry Registry) error {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	sourceDigest := image.Repository + "@" + image.Digest
	producer := "a-novel/" + image.Component
	if err := execute(ctx, io.Discard, "gh", "attestation", "verify", "oci://"+sourceDigest, "--repo", producer,
		"--signer-workflow", producer+"/.github/workflows/release.yaml", "--source-ref", "refs/heads/master", "--deny-self-hosted-runners"); err != nil {
		return errors.New("a release image lacks a valid producer attestation")
	}
	return registry.Verify(ctx, image)
}

// VerifyService binds selected configuration to its complete producer family.
// Promoted also checks immutable destination tags; it never copies images.
func VerifyService(ctx context.Context, manifest string, data []byte, promoted bool, execute func(context.Context, io.Writer, string, ...string) error, registry Registry) error {
	inputs, err := parseService(data)
	if err != nil {
		return err
	}
	images, err := release.VerificationImages(manifest, inputs.Service)
	if err != nil {
		return errors.New("invalid selected image family")
	}
	if err := resolveImages(ctx, images, registry); err != nil {
		return err
	}
	if err := inputs.bindImages(images); err != nil {
		return err
	}
	for _, image := range images {
		if err := verifyImage(ctx, image, execute, registry); err != nil {
			return err
		}
		if promoted {
			image.Repository = inputs.destination(image)
			if err := registry.Verify(ctx, image); err != nil {
				return errors.New("selected promoted image is unavailable or differs from its producer")
			}
		}
	}
	return nil
}
