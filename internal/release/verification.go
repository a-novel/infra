package release

import (
	"encoding/json"
	"errors"
	"regexp"
)

// SourceImage binds a public tag and immutable digest to its producer and role.
type SourceImage struct {
	Component  string // Component names the producer repository under a-novel.
	Slot       string // Slot is the database, API or jobs/role within that producer.
	Repository string // Repository is the public OCI repository without a tag or digest.
	Tag        string // Tag is the family's published SemVer release.
	Digest     string // Digest is resolved during preflight or retained in historical receipts.
}

// VerificationImages reads the existing compiled eight-image inventory when service
// is empty. Otherwise it selects one complete family from the committed manifest.
// Selection performs no registry or cloud requests.
func VerificationImages(file, service string) ([]SourceImage, error) {
	invalid := errors.New("invalid source image inventory")
	if service == "" {
		value, err := read(file, "compiled release", false)
		if err != nil {
			return nil, err
		}
		items, _ := value["images"].([]any)
		schema, _ := value["schemaVersion"].(json.Number)
		major, _ := value["postgresMajor"].(json.Number)
		schemaVersion, _ := schema.Float64()
		postgresMajor, _ := major.Float64()
		if schemaVersion != 1 || postgresMajor != 18 || len(items) != 8 {
			return nil, invalid
		}
		images, seen := []SourceImage{}, map[string]bool{}
		versionPattern := regexp.MustCompile(`^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`)
		digestPattern := regexp.MustCompile(`^sha256:[a-f0-9]{64}$`)
		for _, item := range items {
			image := sourceImage(item, str(item, "component"), str(item, "slot"))
			if image.Component != "service-json-keys" && image.Component != "service-authentication" {
				return nil, invalid
			}
			if image.Repository != "ghcr.io/a-novel/"+image.Component+"/"+image.Slot {
				return nil, invalid
			}
			if !versionPattern.MatchString(image.Tag) || !digestPattern.MatchString(image.Digest) {
				return nil, invalid
			}
			digest := image.Repository + "@" + image.Digest
			if seen[digest] || str(item, "sourceDigest") != digest || str(item, "source") != image.Repository+":"+image.Tag {
				return nil, invalid
			}
			seen[digest] = true
			images = append(images, image)
		}
		return images, nil
	}
	if service != "json-keys" && service != "authentication" {
		return nil, invalid
	}
	compiler, err := NewCompiler()
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
				images = append(images, sourceImage(obj(manifest, "components", name, "images", slot), name, slot))
			}
		}
	}
	return images, nil
}

func sourceImage(value any, component, slot string) SourceImage {
	return SourceImage{component, slot, str(value, "repository"), str(value, "tag"), str(value, "digest")}
}
