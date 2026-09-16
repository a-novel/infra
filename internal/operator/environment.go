package operator

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

func projectIDs(getenv func(string) string) (map[string]string, error) {
	projects := map[string]string{}
	for _, kind := range []string{"MANAGEMENT", "WORKLOAD"} {
		variable := "INFRA_" + kind + "_PROJECT_ID"
		value := getenv(variable)
		if !matches(`[a-z][a-z0-9-]{4,28}[a-z0-9]`, value) {
			return nil, fmt.Errorf("%s is missing or invalid; load the reviewed .envrc", variable)
		}
		projects["GCP_"+kind+"_PROJECT_ID"] = value
	}
	if projects["GCP_MANAGEMENT_PROJECT_ID"] == projects["GCP_WORKLOAD_PROJECT_ID"] {
		return nil, errors.New("management and workload project IDs must differ")
	}
	return projects, nil
}

func verifyPublished(ctx context.Context, projects map[string]string, execute func(context.Context, io.Writer, string, ...string) error) error {
	var output bytes.Buffer
	if err := execute(ctx, &output, "gh", "variable", "list", "--repo", "a-novel/infra", "--json", "name,value"); err != nil {
		return fmt.Errorf("read published project coordinates: %w", err)
	}
	var variables []struct {
		Name  string
		Value *string
	}
	if json.Unmarshal(output.Bytes(), &variables) != nil || variables == nil {
		return errors.New("GitHub did not return the repository variables")
	}
	seen := map[string]bool{}
	for _, variable := range variables {
		if expected, ok := projects[variable.Name]; ok {
			if seen[variable.Name] || variable.Value == nil || *variable.Value != "" && *variable.Value != expected {
				return errors.New("operator selection does not match the published GitHub coordinate")
			}
			seen[variable.Name] = true
		}
	}
	return nil
}
