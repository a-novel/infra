package release

import (
	"errors"
)

// SourceImage binds a public tag and immutable digest to its producer and role.
type SourceImage struct {
	Component  string // Component names the producer repository under a-novel.
	Slot       string // Slot is the database, API or jobs/role within that producer.
	Repository string // Repository is the public OCI repository without a tag or digest.
	Tag        string // Tag is the family's published SemVer release.
	Digest     string // Digest is resolved during preflight or retained in historical receipts.
}

// VerificationImages selects one complete service family from the committed manifest.
// Selection performs no registry or cloud requests.
func VerificationImages(file, service string) ([]SourceImage, error) {
	invalid := errors.New("invalid source image inventory")
	if service != "json-keys" && service != "authentication" {
		return nil, invalid
	}
	compiler, err := newValidator()
	if err != nil {
		return nil, err
	}
	manifest, err := compiler.load(file, "images")
	if err != nil {
		return nil, err
	}
	if err = familyVersions(manifest, service); err != nil {
		return nil, err
	}
	images := []SourceImage{}
	for _, family := range families {
		name := component(family.service)
		if name == "service-"+service {
			for _, slot := range family.slots {
				if image := obj(manifest, "components", name, "images", slot); image != nil {
					images = append(images, sourceImage(image, name, slot))
				}
			}
		}
	}
	return images, nil
}

func sourceImage(value any, component, slot string) SourceImage {
	return SourceImage{component, slot, str(value, "repository"), str(value, "tag"), str(value, "digest")}
}
