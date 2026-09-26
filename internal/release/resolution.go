package release

import (
	"errors"
	"regexp"
)

var imageDigestPattern = regexp.MustCompile(`^sha256:[a-f0-9]{64}$`)

func versionInputs(manifest object) error {
	for _, family := range families {
		for _, slot := range family.slots {
			if at(manifest, "components", component(family.service), "images", slot, "digest") != nil {
				return errors.New("maintained image inputs must use SemVer alone; digests belong to generated snapshots")
			}
		}
	}
	return nil
}

// ResolveManifest writes a private deployment snapshot after the entire family
// inventory passes resolve. The callback owns registry and provenance checks.
func ResolveManifest(source, output string, resolve func(SourceImage) (string, error)) error {
	compiler, err := NewCompiler()
	if err != nil {
		return err
	}
	manifest, err := compiler.load(source, "images")
	if err != nil {
		return err
	}
	if err = familyVersions(manifest); err != nil {
		return err
	}
	if err = versionInputs(manifest); err != nil {
		return err
	}
	for _, family := range families {
		name := component(family.service)
		for _, slot := range family.slots {
			image := obj(manifest, "components", name, "images", slot)
			digest, err := resolve(sourceImage(image, name, slot))
			if err != nil {
				return err
			}
			if !imageDigestPattern.MatchString(digest) {
				return errors.New("invalid resolved image digest")
			}
			image["digest"] = digest
		}
	}
	return writePrivate(output, manifest)
}

// bindReceiptImages keeps offline maintenance and rollback tied to receipt-owned
// images. A new version must have been resolved by preflight before compilation.
func bindReceiptImages(manifest, previous object) error {
	for _, family := range families {
		name := component(family.service)
		for _, slot := range family.slots {
			image := obj(manifest, "components", name, "images", slot)
			prior := obj(previous, "components", name, "images", slot)
			if image == nil {
				return errors.New("missing image inventory")
			}
			if image["digest"] == nil && image["repository"] == prior["repository"] && image["tag"] == prior["tag"] {
				image["digest"] = prior["digest"]
			}
			if !imageDigestPattern.MatchString(str(image, "digest")) {
				return errors.New("resolve the image manifest before compiling a new release")
			}
		}
	}
	return nil
}
