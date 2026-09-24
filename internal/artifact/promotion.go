package artifact

import (
	"context"
	"encoding/json/v2"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"

	"github.com/google/go-containerregistry/pkg/name"

	"github.com/a-novel/infra/internal/release"
)

type promotion struct {
	Source string `json:"source"`
	Target string `json:"target"`
	Tag    string `json:"tag"`
	Digest string `json:"digest"`
}

// Promote copies reviewed images without applying resources or running jobs.
// Legacy releases retain their preceding provenance preflight; recovery uses a
// previously validated receipt. The standalone service path verifies its entire
// family before the first copy.
func Promote(ctx context.Context, args []string, execute func(context.Context, io.Writer, string, ...string) error, registry Registry, stdout, stderr io.Writer) int {
	stop := func(code int, message string) int {
		_, _ = fmt.Fprintln(stderr, message)
		return code
	}
	var copies []promotion
	var sources []release.SourceImage
	var err error
	switch {
	case len(args) >= 2 && len(args) <= 3 && args[0] == "release":
		copies, err = releasePromotions(args[1], args[2:])
	case len(args) == 2 && args[0] == "recovery":
		err = readInventory(args[1], &copies)
		if err == nil {
			err = recoveryPromotions(copies)
		}
	case len(args) == 3 && args[0] == "service":
		var inputs serviceInputs
		inputs, err = readService(args[2])
		if err == nil {
			sources, err = release.VerificationImages(args[1], inputs.Service)
		}
		if err == nil {
			err = inputs.bindImages(sources)
		}
		for _, image := range sources {
			copies = append(copies, promotion{Source: image.Repository + "@" + image.Digest, Tag: inputs.destination(image) + ":" + image.Tag})
		}
	default:
		return stop(64, "Usage: infra promote release <compiled-release> [receipt-run-id] | recovery <images.json> | service <manifest> <tfvars>")
	}
	if err != nil {
		return stop(65, "Image promotion inputs are invalid; no copy attempted.")
	}
	for _, image := range sources {
		if err = verifyImage(ctx, image, execute, registry); err != nil {
			return stop(70, err.Error())
		}
	}
	for index, image := range copies {
		if err = registry.Copy(ctx, image.Source, image.Tag); err != nil {
			return stop(70, fmt.Sprintf("Image promotion %d/%d: %s", index+1, len(copies), err))
		}
	}
	if _, err = fmt.Fprintln(stdout, "All reviewed image copies are confirmed at their exact digests."); err != nil {
		return stop(70, "Cannot report image promotion.")
	}
	return 0
}

func readInventory(file string, value any) error {
	data, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, value)
}

func releasePromotions(file string, receipt []string) ([]promotion, error) {
	images, err := release.VerificationImages(file, "")
	if err != nil {
		return nil, err
	}
	var compiled struct {
		Cloud struct {
			Region            string `json:"region"`
			WorkloadProjectID string `json:"workloadProjectId"`
		} `json:"cloud"`
		Images []struct {
			Promoted    string `json:"promoted"`
			PromotedTag string `json:"promotedTag"`
		} `json:"images"`
	}
	err = readInventory(file, &compiled)
	if err != nil {
		return nil, err
	}
	invalid := errors.New("invalid release destination")
	if len(compiled.Images) != len(images) {
		return nil, invalid
	}
	if len(receipt) != 0 && !regexp.MustCompile(`^[1-9][0-9]*$`).MatchString(receipt[0]) {
		return nil, invalid
	}
	inputs := serviceInputs{Region: compiled.Cloud.Region, Project: compiled.Cloud.WorkloadProjectID}
	var copies []promotion
	for index, image := range images {
		repository := inputs.destination(image)
		if !registryRepository.MatchString(repository) {
			return nil, invalid
		}
		target := repository + "@" + image.Digest
		tag := repository + ":" + image.Tag
		if compiled.Images[index].Promoted != target || compiled.Images[index].PromotedTag != tag {
			return nil, invalid
		}
		copies = append(copies, promotion{Source: image.Repository + "@" + image.Digest, Tag: tag})
		if len(receipt) != 0 {
			copies = append(copies, promotion{Source: target, Tag: repository + ":receipt-" + receipt[0]})
		}
	}
	return copies, nil
}

var registryRepository = regexp.MustCompile(`^[a-z]+-[a-z]+[1-9][0-9]*-docker\.pkg\.dev/[a-z][a-z0-9-]{4,28}[a-z0-9]/agora-production/service-(json-keys/(database|grpc|jobs/(migrations|rotatekeys))|authentication/(database|rest|jobs/(init|migrations)))$`)

func recoveryPromotions(copies []promotion) error {
	invalid := errors.New("invalid recovery inventory")
	if len(copies) != 8 {
		return invalid
	}
	seen := map[string]bool{}
	var scope string
	for _, image := range copies {
		source, sourceErr := name.NewDigest(image.Source, name.StrictValidation)
		target, targetErr := name.NewDigest(image.Target, name.StrictValidation)
		tag, tagErr := name.NewTag(image.Tag, name.StrictValidation)
		if sourceErr != nil || targetErr != nil || tagErr != nil {
			return invalid
		}
		if source.Name() != image.Source || target.Name() != image.Target || !strings.HasPrefix(image.Digest, "sha256:") {
			return invalid
		}
		if source.DigestStr() != image.Digest || target.DigestStr() != image.Digest || tag.Context() != target.Context() {
			return invalid
		}
		if !registryRepository.MatchString(source.Context().Name()) || !registryRepository.MatchString(target.Context().Name()) ||
			!regexp.MustCompile(`^recovery-[1-9][0-9]*$`).MatchString(tag.TagStr()) {
			return invalid
		}
		sourceParts, targetParts := strings.SplitN(source.Context().Name(), "/", 4), strings.SplitN(target.Context().Name(), "/", 4)
		if sourceParts[3] != targetParts[3] || seen[targetParts[3]] || sourceParts[1] == targetParts[1] {
			return invalid
		}
		current := strings.Join(sourceParts[:3], "/") + " " + strings.Join(targetParts[:3], "/") + " " + tag.TagStr()
		if scope != "" && scope != current {
			return invalid
		}
		scope, seen[targetParts[3]] = current, true
	}
	return nil
}
