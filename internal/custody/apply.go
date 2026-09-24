package custody

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"

	"google.golang.org/api/option"

	"github.com/a-novel/infra/internal/workflow"
)

// apply owns admission through configuration publication for the inactive service
// roots. Legacy roots retain their existing external receipt/configuration owner.
func (storage store) apply(args []string, getenv func(string) string, output io.Writer, options []option.ClientOption) error {
	if len(args) != 4 {
		return failure{64, "Usage: infra custody plan apply <bucket> <root> <commit> <plan-id> <tfvars>"}
	}
	root, commit, planID, inputs := args[0], args[1], args[2], args[3]
	suffix := getenv("TOFU_STATE_SUFFIX")
	service := root == "service-foundation" || root == "service-release"
	data, err := os.ReadFile(inputs)
	if err != nil || !json.Valid(data) {
		return failure{64, "Apply requires readable private JSON inputs."}
	}
	// Use the same private snapshot for plan binding, apply, convergence and publication.
	inputs = filepath.Join(storage.scratch, "inputs.json")
	if err := os.WriteFile(inputs, data, 0o600); err != nil {
		return err
	}
	if service {
		enabled := "SERVICE_FOUNDATIONS_ENABLED"
		if root == "service-release" {
			enabled = "SERVICE_JOB_BOOTSTRAP_ENABLED"
		}
		if getenv(enabled) != "true" {
			return failure{77, "Service apply requires separate activation approval."}
		}
		if workflow.FoundationInputs([]string{"check", inputs, storage.bucket, suffix}, getenv, io.Discard, io.Discard) != 0 {
			return failure{65, "Service apply does not match protected registration."}
		}
		if commit != getenv("GITHUB_SHA") || getenv("GITHUB_REPOSITORY") != "a-novel/infra" {
			return failure{65, "Service apply must identify the exact trusted workflow commit."}
		}
		if _, err := sequenceName(getenv("GITHUB_RUN_ID")+"-"+getenv("GITHUB_RUN_ATTEMPT"), ""); err != nil {
			return err
		}
	}
	plan := filepath.Join(storage.scratch, "reviewed.tfplan")
	fetch := []string{root, commit, planID, plan}
	if service {
		fetch = append(fetch, inputs)
	}
	if err := storage.plan("fetch", fetch, suffix); err != nil {
		return err
	}
	marker, err := os.ReadFile(plan + ".destructive")
	if err != nil {
		return err
	}
	destructive := strings.TrimSpace(string(marker))
	if destructive == "true" {
		if err := storage.execute(storage.ctx, io.Discard, "./ops/verify-deletion-label.sh", getenv("GITHUB_REPOSITORY"), commit); err != nil {
			return failure{77, "Managed-resource deletion requires approval on the exact merged PR."}
		}
	}
	var operation *serviceOperation
	if service {
		operation, err = storage.admit(args[:3], data, plan, getenv, output, options)
		if err != nil {
			return err
		}
	}
	// No cleanup handler releases admission: providers can keep working after a lost runner.
	if err := storage.plan("consume", args[:3], suffix); err != nil {
		return err
	}
	for _, action := range []string{"apply", "converge"} {
		command := []string{
			"ALLOW_RESOURCE_DELETION=" + destructive, "TOFU_VAR_FILE=" + inputs,
			"./ops/tofu-gate.sh", action, root, storage.bucket,
		}
		if action == "apply" {
			command = append(command, plan)
		}
		if err := storage.execute(storage.ctx, output, "env", command...); err != nil {
			return failure{1, "Reviewed apply or convergence failed; reconcile the resources and any held service guard before continuing."}
		}
	}
	if operation != nil {
		return operation.finish(storage.ctx, data)
	}
	return nil
}
