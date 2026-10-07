package artifact

import (
	"context"
	"fmt"
	"io"

	"github.com/a-novel/infra/internal/release"
)

type promotion struct {
	Source string `json:"source"`
	Tag    string `json:"tag"`
}

// Promote copies reviewed images without applying resources or running jobs.
// The selected service family passes provenance checks before the first copy.
func Promote(ctx context.Context, args []string, execute func(context.Context, io.Writer, string, ...string) error, registry Registry, stdout, stderr io.Writer) int {
	stop := func(code int, message string) int {
		_, _ = fmt.Fprintln(stderr, message)
		return code
	}
	var copies []promotion
	var sources []release.SourceImage
	var err error
	switch {
	case len(args) == 3 && args[0] == "service":
		var inputs serviceInputs
		inputs, err = readService(args[2])
		if err == nil {
			sources, err = release.VerificationImages(args[1], inputs.Service)
		}
		if err == nil {
			err = resolveImages(ctx, sources, registry)
		}
		if err == nil {
			err = inputs.bindImages(sources)
		}
		for _, image := range sources {
			copies = append(copies, promotion{Source: image.Repository + "@" + image.Digest, Tag: inputs.destination(image) + ":" + image.Tag})
		}
	default:
		return stop(64, "Usage: infra promote service <manifest> <tfvars>")
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
