package inspection

import (
	"context"
	"fmt"
	"io"
	"maps"
	"os"
	"slices"
	"strings"

	"github.com/a-novel/infra/internal/workflow"
)

func (i inspector) services(ctx context.Context, mode string, result *verdict) error {
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
	scopes, err := workflow.ServiceFoundationScopes(getenv, i.bucket)
	if err != nil {
		return failure{70, "Service registration does not match the protected management coordinates."}
	}
	// Native backend metadata distinguishes a never-initialized project from
	// orphaned or partially initialized state. A denied list is not an empty list.
	data, err := i.execute(ctx, nil, "gcloud", "storage", "objects", "list", "gs://"+i.bucket+"/foundation/services/**", "--format=value(name)")
	if err != nil {
		return failure{70, "Could not inventory service foundation state."}
	}
	states := map[string]bool{}
	for name := range strings.FieldsSeq(string(data)) {
		path, ok := strings.CutPrefix(name, "foundation/")
		parts := strings.SplitN(path, "/", 3)
		if !ok || len(parts) != 3 {
			return failure{70, "Unexpected service foundation state metadata."}
		}
		scope := strings.Join(parts[:2], "/")
		if _, registered := scopes[scope]; !registered {
			return failure{70, "Unregistered service foundation state requires reconciliation."}
		}
		if parts[2] != "default.tfstate" && !strings.HasPrefix(parts[2], "config/") {
			return failure{70, "Unexpected workspace or lock in service foundation state."}
		}
		states[scope] = states[scope] || parts[2] == "default.tfstate"
	}
	for _, scope := range slices.Sorted(maps.Keys(scopes)) {
		service := scopes[scope]
		initialized, present := states[scope]
		if !present {
			if _, err := fmt.Fprintf(i.output, "%s foundation has no state or inputs; skipped.\n", service); err != nil {
				return err
			}
			continue
		}
		if !initialized {
			return failure{70, "Service foundation inputs exist without their default workspace state."}
		}
		if _, err := fmt.Fprintf(i.output, "Inspecting %s foundation.\n", service); err != nil {
			return err
		}
		file, code := i.config(ctx, "service-foundation", scope)
		if code != 0 || workflow.FoundationInputs([]string{"check", file, i.bucket, scope}, getenv, io.Discard, io.Discard) != 0 {
			return failure{70, "Service foundation state lacks matching converged inputs."}
		}
		env := []string{"TOFU_STATE_SUFFIX=" + scope, "FOUNDATION_CONFIG=" + string(registration)}
		if err := i.assessOrDrift(ctx, mode, "service-foundation", file, env, result); err != nil {
			return err
		}
	}
	return nil
}
