package hostcredentials_test

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/hostcredentials"
)

func TestServiceAccount(t *testing.T) {
	t.Parallel()
	testCases := []struct {
		name, project, service, endpoint, account string
	}{
		{"Success/JSONKeysDatabase", "example-private", "json-keys", "database", "agora-json-keys-database"},
		{"Success/JSONKeysRepository", "example-private", "json-keys", "repository", "agora-pgbr-json-keys"},
		{"Success/AuthenticationDatabase", "example-private", "authentication", "database", "agora-auth-database"},
		{"Success/AuthenticationRepository", "example-private", "authentication", "repository", "agora-pgbr-authentication"},
		{"Success/GenAIDatabase", "example-private", "genai", "database", "agora-genai-database"},
		{"Success/GenAIRepository", "example-private", "genai", "repository", "agora-pgbr-genai"},
		{"Error/Service", "example-private", "peer", "database", ""},
		{"Error/MissingService", "example-private", "", "database", ""},
		{"Error/Endpoint", "example-private", "json-keys", "recovery", ""},
		{"Error/Project", "example-private\n", "json-keys", "database", ""},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			account, err := hostcredentials.ServiceAccount(testCase.project, testCase.service, testCase.endpoint)
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
