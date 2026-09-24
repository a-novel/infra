package release_test

import (
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/release"
)

func TestVerificationImages(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name   string
		mutate func(object)
	}{
		{"Schema", func(v object) { v["schemaVersion"] = 2 }},
		{"Major", func(v object) { v["postgresMajor"] = 17 }},
		{"Count", func(v object) { v["images"] = v["images"].([]any)[:7] }},
		{"Duplicate", func(v object) { v["images"].([]any)[1] = v["images"].([]any)[0] }},
		{"Component", func(v object) { v["images"].([]any)[0].(object)["component"] = "private-diagnostic" }},
		{"Tag", func(v object) { v["images"].([]any)[0].(object)["tag"] = "latest" }},
		{"Digest", func(v object) { v["images"].([]any)[0].(object)["digest"] = "private-diagnostic" }},
		{"Source", func(v object) { v["images"].([]any)[0].(object)["source"] = "private-diagnostic" }},
		{"SourceDigest", func(v object) { v["images"].([]any)[0].(object)["sourceDigest"] = "private-diagnostic" }},
	} {
		t.Run("Error/"+testCase.name, func(t *testing.T) {
			t.Parallel()
			fixture := setup(t)
			file := filepath.Join(fixture.first, "release.json")
			value := read(t, file)
			testCase.mutate(value)
			write(t, file, value)
			_, err := release.VerificationImages(file, "")
			require.Error(t, err)
			require.NotContains(t, err.Error(), "private-diagnostic")
		})
	}
}
