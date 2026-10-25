package hostcredentials

import (
	"errors"
	"regexp"
	"slices"
)

var (
	projectID = regexp.MustCompile(`^[a-z][a-z0-9-]{4,28}[a-z0-9]$`)
	// privateDatabaseAccounts names each service's database host identity in the private project.
	privateDatabaseAccounts = map[string]string{
		"json-keys":      "agora-json-keys-database",
		"authentication": "agora-auth-database",
		"genai":          "agora-genai-database",
	}
)

// ServiceAccount returns the identity a service's endpoint host must run as, in the project of the
// private trust zone, before the host authenticates with it.
func ServiceAccount(project, service, endpoint, zone string) (string, error) {
	if !slices.Contains(services, service) {
		return "", errors.New("invalid service")
	}
	if !projectID.MatchString(project) {
		return "", errors.New("invalid workload project")
	}
	if zone != "private" {
		return "", errors.New("invalid trust zone")
	}
	var account string
	switch endpoint {
	case "database":
		account = privateDatabaseAccounts[service]
	case "repository":
		account = "agora-pgbr-" + service
	default:
		return "", errors.New("invalid endpoint")
	}
	return account + "@" + project + ".iam.gserviceaccount.com", nil
}
