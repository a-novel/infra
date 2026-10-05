package hostcredentials_test

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/hostcredentials"
)

func TestServiceAccount(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, project, endpoint, zone, account string
	}{
		{"Success/DedicatedDatabase", "example-private", "database", "", "agora-database"},
		{"Success/DedicatedRepository", "example-private", "repository", "", "agora-backup-repository"},
		{"Success/SharedDatabase", "example-private", "database", "private", "agora-json-keys-database"},
		{"Success/SharedRepository", "example-private", "repository", "private", "agora-pgbr-json-keys"},
		{"Error/PublicAPI", "example-private", "database", "public-api", ""},
		{"Error/Public", "example-private", "repository", "public", ""},
		{"Error/Endpoint", "example-private", "recovery", "private", ""},
		{"Error/Project", "example-private\n", "database", "private", ""},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			account, err := hostcredentials.ServiceAccount(testCase.project, testCase.endpoint, testCase.zone)
			if testCase.account == "" {
				require.Error(t, err)
				require.Empty(t, account)
				return
			}
			require.NoError(t, err)
			require.Equal(t, testCase.account+"@"+testCase.project+".iam.gserviceaccount.com", account)
		})
	}
}
