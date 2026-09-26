package release_test

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestVersionOnlyCompilation(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, action                       string
		newVersion, firstLaunch, wantError bool
	}{
		{"Maintenance", "deploy", false, false, false},
		{"RollbackIgnoresNewTags", "rollback", true, false, false},
		{"NewVersionNeedsPreflight", "deploy", true, false, true},
		{"LaunchNeedsPreflight", "deploy", false, true, true},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			fixture := setup(t)
			if testCase.newVersion {
				fixture.change("json_keys", true)
			}
			if testCase.firstLaunch {
				fixture.files[2], fixture.receipt = "-", nil
			}
			for _, component := range section(fixture.manifest, "components") {
				for _, image := range component.(object)["images"].(object) {
					delete(image.(object), "digest")
				}
			}
			err := fixture.compile(t, testCase.action, "", "")
			if testCase.wantError {
				require.ErrorContains(t, err, "resolve the image manifest")
				require.NoDirExists(t, fixture.files[3])
				return
			}
			require.NoError(t, err)
			require.Equal(t, fixture.receipt["imageManifest"], result(t, fixture, "release.json")["imageManifest"])
		})
	}
}
