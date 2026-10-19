package hostcredentials

import (
	"errors"
	"regexp"
	"slices"
)

var (
	projectID = regexp.MustCompile(`^[a-z][a-z0-9-]{4,28}[a-z0-9]$`)
	// privateDatabaseAccounts names each service's database host identity in the shared private project.
	privateDatabaseAccounts = map[string]string{
		"json-keys":      "agora-json-keys-database",
		"authentication": "agora-auth-database",
	}
)

// ServiceAccount selects the exact service endpoint identity before metadata authentication.
// An empty zone retains dedicated-project identities; private selects shared-project identities.
func ServiceAccount(project, service, endpoint, zone string) (string, error) {
	if !slices.Contains(services, service) {
		return "", errors.New("invalid service")
	}
	if !projectID.MatchString(project) {
		return "", errors.New("invalid workload project")
	}
	var account string
	switch zone + "/" + endpoint {
	case "/database":
		account = "agora-database"
	case "/repository":
		account = "agora-backup-repository"
	case "private/database":
		account = privateDatabaseAccounts[service]
	case "private/repository":
		account = "agora-pgbr-" + service
	default:
		return "", errors.New("invalid endpoint or trust zone")
	}
	return account + "@" + project + ".iam.gserviceaccount.com", nil
}
