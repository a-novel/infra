package hostcredentials_test

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/hostcredentials"
)

func TestServiceAccount(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, project, service, endpoint, zone, account string
	}{
		{"Success/DedicatedDatabase", "example-private", "json-keys", "database", "", "agora-database"},
		{"Success/DedicatedRepository", "example-private", "json-keys", "repository", "", "agora-backup-repository"},
		{"Success/JSONKeysDatabase", "example-private", "json-keys", "database", "private", "agora-json-keys-database"},
		{"Success/JSONKeysRepository", "example-private", "json-keys", "repository", "private", "agora-pgbr-json-keys"},
		{"Success/AuthenticationDatabase", "example-private", "authentication", "database", "private", "agora-auth-database"},
		{"Success/AuthenticationRepository", "example-private", "authentication", "repository", "private", "agora-pgbr-authentication"},
		{"Error/PublicAPI", "example-private", "authentication", "database", "public-api", ""},
		{"Error/Public", "example-private", "json-keys", "repository", "public", ""},
		{"Error/Service", "example-private", "peer", "database", "private", ""},
		{"Error/MissingService", "example-private", "", "database", "private", ""},
		{"Error/Endpoint", "example-private", "json-keys", "recovery", "private", ""},
		{"Error/Project", "example-private\n", "json-keys", "database", "private", ""},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			account, err := hostcredentials.ServiceAccount(testCase.project, testCase.service, testCase.endpoint, testCase.zone)
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
