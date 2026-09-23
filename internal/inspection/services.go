package inspection

import (
	"context"
	"fmt"
	"io"
	"maps"
	"os"
	"regexp"
	"slices"
	"strings"

	"github.com/a-novel/infra/internal/workflow"
)

var servicePlanObject = regexp.MustCompile(`^plans/[a-f0-9]{40}/[1-9][0-9]{0,19}-[1-9][0-9]{0,4}/(plan\.tfplan|plan\.metadata\.json)$`)

func (i inspector) services(ctx context.Context, mode, root string, result *verdict) error {
	file, code := i.config(ctx, "foundation", "")
	registration := []byte(`{}`)
	if code == 0 {
		var err error
		registration, err = os.ReadFile(file)
		if err != nil {
			return err
		}
	} else if code != 4 {
		return failure{70, "Could not read the converged service registration."}
	}
	getenv := func(key string) string {
		if key == "FOUNDATION_CONFIG" {
			return string(registration)
		}
		return i.getenv(key)
	}
	scopes, err := workflow.ServiceScopes(getenv, i.bucket)
	if err != nil {
		return failure{70, "Service registration does not match the protected management coordinates."}
	}
	states, err := i.serviceStates(ctx, root, scopes)
	if err != nil {
		return err
	}
	for _, scope := range slices.Sorted(maps.Keys(scopes)) {
		service := scopes[scope]
		initialized, present := states[scope]
		if !present {
			if _, err := fmt.Fprintf(i.output, "%s %s has no state or inputs; skipped.\n", service, root); err != nil {
				return err
			}
			continue
		}
		if !initialized {
			return failure{70, "Service inputs exist without their default workspace state."}
		}
		if _, err := fmt.Fprintf(i.output, "Inspecting %s %s.\n", service, root); err != nil {
			return err
		}
		file, code := i.config(ctx, root, scope)
		if code != 0 || workflow.FoundationInputs([]string{"check", file, i.bucket, scope}, getenv, io.Discard, io.Discard) != 0 {
			return failure{70, "Service state lacks matching converged inputs."}
		}
		env := []string{"TOFU_STATE_SUFFIX=" + scope, "FOUNDATION_CONFIG=" + string(registration)}
		if err := i.assessOrDrift(ctx, mode, root, file, env, result); err != nil {
			return err
		}
	}
	return nil
}

func (i inspector) serviceStates(ctx context.Context, root string, scopes map[string]string) (map[string]bool, error) {
	prefixes := []string{"foundation/services/"}
	if root == "service-release" {
		// Folder metadata is bucket-wide; object reads are granted only within
		// each exact service folder. Inventory must retain that IAM boundary.
		data, err := i.execute(ctx, nil, "gcloud", "storage", "managed-folders", "list", "gs://"+i.bucket+"/services/", "--raw", "--format=value(name)")
		if err != nil {
			return nil, failure{70, "Could not inventory service release folders."}
		}
		prefixes = strings.Fields(string(data))
		folders := map[string]bool{}
		for _, prefix := range prefixes {
			scope, ok := strings.CutSuffix(prefix, "/release/")
			if !ok || scopes[scope] == "" || folders[scope] {
				return nil, failure{70, "Unexpected or unregistered service release folder requires reconciliation."}
			}
			folders[scope] = true
		}
		if len(folders) != len(scopes) {
			return nil, failure{70, "Registered service release folder is missing."}
		}
	}
	states := map[string]bool{}
	for _, prefix := range prefixes {
		data, err := i.execute(ctx, nil, "gcloud", "storage", "objects", "list", "gs://"+i.bucket+"/"+prefix+"**", "--format=value(name)")
		if err != nil {
			return nil, failure{70, "Could not inventory service state."}
		}
		for name := range strings.FieldsSeq(string(data)) {
			parts := strings.SplitN(strings.TrimPrefix(name, "foundation/"), "/", 3)
			if !strings.HasPrefix(name, prefix) || len(parts) != 3 {
				return nil, failure{70, "Unexpected service state metadata."}
			}
			scope := strings.Join(parts[:2], "/")
			if scopes[scope] == "" {
				return nil, failure{70, "Unregistered service state requires reconciliation."}
			}
			object := parts[2]
			if root == "service-release" {
				object = strings.TrimPrefix(object, "release/")
				if servicePlanObject.MatchString(object) {
					continue
				}
			}
			if object != "default.tfstate" && !strings.HasPrefix(object, "config/") {
				return nil, failure{70, "Unexpected workspace or lock in service state."}
			}
			states[scope] = states[scope] || object == "default.tfstate"
		}
	}
	return states, nil
}
