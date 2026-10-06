package inspection

import (
	"context"
	"encoding/json"
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
	scopes, err := workflow.ReleaseScopes(getenv, i.bucket)
	if err != nil {
		return failure{70, "Service registration does not match the protected management coordinates."}
	}
	// A shared guard excludes both zones of the same service. Even an orphaned
	// guard blocks assessment; registration removal cannot silently abandon it.
	guards, err := i.liveObjects(ctx, "foundation/operations/production/")
	if err != nil || len(guards) != 0 {
		return failure{70, "Shared operation inventory is unreadable or held; reconcile it before assessment."}
	}
	if root != "service-release" {
		// Admission belongs to the source service, including before foundation
		// or disposable recovery state exists.
		releases, err := i.serviceStates(ctx, "service-release", scopes)
		if err != nil {
			return err
		}
		for scope, initialized := range releases {
			if !initialized {
				return failure{70, "Service release inputs exist without state."}
			}
			file, code := i.config(ctx, "service-release", scope)
			if code != 0 || workflow.FoundationInputs([]string{"check-release", file, i.bucket, scope}, getenv, io.Discard, io.Discard) != 0 {
				return failure{70, "Service release state lacks matching converged inputs."}
			}
		}
	}
	check := workflow.FoundationInputs
	checkAction := "check"
	if root == "service-foundation" {
		checkAction = "check-foundation"
	}
	if root == "service-release" {
		checkAction = "check-release"
	}
	if root == "service-recovery" {
		scopes, err = workflow.RecoveryScopes(getenv, i.bucket)
		if err != nil {
			return failure{70, "Recovery destinations do not match protected registration."}
		}
		check = workflow.RecoveryInputs
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
		if code != 0 || check([]string{checkAction, file, i.bucket, scope}, getenv, io.Discard, io.Discard) != 0 {
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
	prefixes := []string{"foundation/services/", "foundation/workloads/"}
	if root == "service-recovery" {
		prefixes = []string{"foundation/recovery/services/"}
	}
	if root == "service-release" {
		// Folder metadata is bucket-wide; object reads are granted only within
		// each exact service folder. Inventory must retain that IAM boundary.
		prefixes = nil
		for _, namespace := range []string{"services/", "workloads/"} {
			data, err := i.execute(ctx, nil, "gcloud", "storage", "managed-folders", "list", "gs://"+i.bucket+"/"+namespace, "--raw", "--format=value(name)")
			if err != nil {
				return nil, failure{70, "Could not inventory service release folders."}
			}
			prefixes = append(prefixes, strings.Fields(string(data))...)
		}
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
		names, err := i.liveObjects(ctx, prefix)
		if err != nil {
			return nil, failure{70, "Could not inventory service state."}
		}
		for _, name := range names {
			scope, object := strings.TrimSuffix(prefix, "/release/"), strings.TrimPrefix(name, prefix)
			if root != "service-release" {
				length := 3
				if prefix == "foundation/workloads/" {
					length = 6
				}
				parts := strings.SplitN(strings.TrimPrefix(strings.TrimPrefix(name, "foundation/"), "recovery/"), "/", length)
				if len(parts) != length {
					return nil, failure{70, "Unexpected service state metadata."}
				}
				scope, object = strings.Join(parts[:length-1], "/"), parts[length-1]
			}
			if scopes[scope] == "" {
				return nil, failure{70, "Unregistered service state requires reconciliation."}
			}
			if root == "service-release" {
				if object == "operation.json" {
					return nil, failure{70, "A service operation is held; reconcile it before assessment or further mutation."}
				}
				if servicePlanObject.MatchString(object) {
					continue
				}
			}
			if root == "service-recovery" && slices.Contains([]string{"restore-attempt.json", "files-restored.json", "sql-verified.json", "cleanup-attempt.json"}, object) {
				// These permanent reservations and evidence are not active locks.
				// Source admission above still blocks uncertain operations.
				continue
			}
			if object != "default.tfstate" && !strings.HasPrefix(object, "config/") {
				return nil, failure{70, "Unexpected workspace or lock in service state."}
			}
			states[scope] = states[scope] || object == "default.tfstate"
		}
	}
	return states, nil
}

// liveObjects excludes retained generations from the active state and lock inventory.
func (i inspector) liveObjects(ctx context.Context, prefix string) ([]string, error) {
	data, err := i.execute(ctx, nil, "gcloud", "storage", "objects", "list", "gs://"+i.bucket+"/"+prefix+"**", "--raw", "--format=json(name,timeDeleted)")
	var objects []struct{ Name, TimeDeleted string }
	if err != nil || json.Unmarshal(data, &objects) != nil || objects == nil {
		return nil, failure{70, "Could not inventory live storage objects."}
	}
	names := []string{}
	for _, object := range objects {
		if !strings.HasPrefix(object.Name, prefix) {
			return nil, failure{70, "Unexpected storage object metadata."}
		}
		if object.TimeDeleted == "" {
			names = append(names, object.Name)
		}
	}
	return names, nil
}
