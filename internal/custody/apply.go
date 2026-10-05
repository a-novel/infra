package custody

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"google.golang.org/api/option"

	"github.com/a-novel/infra/internal/diagnostics"
	"github.com/a-novel/infra/internal/workflow"
)

// apply owns admission through native verification and configuration publication.
// Legacy roots retain their existing external receipt/configuration owner.
func (storage store) apply(args []string, getenv func(string) string, output io.Writer, options []option.ClientOption) error {
	if len(args) != 4 {
		return failure{64, "Usage: infra custody plan apply <bucket> <root> <commit> <plan-id> <tfvars>"}
	}
	root, commit, planID, inputs := args[0], args[1], args[2], args[3]
	suffix := getenv("TOFU_STATE_SUFFIX")
	legacy := root == "foundation" && suffix == ""
	if legacy {
		if err := storage.checkLegacyMaintenance(options); err != nil {
			return err
		}
	}
	service := root == "service-foundation" || root == "service-release" || root == "service-recovery"
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
		check := workflow.FoundationInputs
		checkAction := "check"
		if root == "service-foundation" {
			checkAction = "check-foundation"
		}
		if root == "service-release" {
			enabled = "SERVICE_JOB_BOOTSTRAP_ENABLED"
			checkAction = "check-release"
		}
		if root == "service-recovery" {
			enabled, check = "NATIVE_RECOVERY_PREPARATION_ENABLED", workflow.RecoveryInputs
			if !workflow.RecoveryEnabled(getenv) || getenv("RECOVERY_OPERATION") != "apply-native" {
				return failure{77, "Native host preparation requires its exact protected workflow."}
			}
		}
		if getenv(enabled) != "true" {
			return failure{77, "Service apply requires separate activation approval."}
		}
		if check([]string{checkAction, inputs, storage.bucket, suffix}, getenv, io.Discard, io.Discard) != 0 {
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
	var upkeep maintenance
	var legacyOperation *legacyMaintenance
	if root == "service-foundation" || legacy {
		command := []string{
			"ALLOW_RESOURCE_DELETION=" + destructive, "TOFU_VAR_FILE=" + inputs,
			"./ops/tofu-gate.sh", "inspect", root, storage.bucket, plan,
		}
		if err := storage.execute(storage.ctx, io.Discard, "env", command...); err != nil {
			return failure{65, "Reviewed foundation plan could not be inspected; no admission or apply attempted."}
		}
		if legacy {
			legacyOperation, err = storage.admitLegacyMaintenance(plan, inputs, commit, planID, getenv, output, options)
		} else {
			upkeep, err = plannedMaintenance(plan+".json", data, getenv)
		}
		if err != nil {
			return err
		}
	}
	var operation *serviceOperation
	if service {
		operation, err = storage.admit(args[:3], data, plan, getenv, output, options)
		if err != nil {
			return err
		}
	}
	if err := storage.releaseChecks(data, operation, true, options); err != nil {
		return err
	}
	// No cleanup handler releases admission: providers can keep working after a lost runner.
	if err := storage.plan("consume", args[:3], suffix); err != nil {
		return err
	}
	for _, host := range upkeep.hosts {
		if err := storage.quiesce(host); err != nil {
			return failure{70, "Native host quiescence is unconfirmed; no apply attempted. Keep the service guard and reconcile the original operation."}
		}
	}
	for _, action := range []string{"apply", "converge"} {
		diagnosticFile := filepath.Join(storage.scratch, action+"-diagnostics.tsv")
		command := []string{
			"ALLOW_RESOURCE_DELETION=" + destructive, "TOFU_VAR_FILE=" + inputs,
			"TOFU_DIAGNOSTICS_FILE=" + diagnosticFile,
			"./ops/tofu-gate.sh", action, root, storage.bucket,
		}
		if action == "apply" {
			command = append(command, plan)
		}
		if err := storage.execute(storage.ctx, output, "env", command...); err != nil {
			message := fmt.Sprintf("Reviewed %s failed; reconcile the resources and any held service guard before continuing.", action)
			// Failures before OpenTofu starts have no diagnostic file.
			if data, err := os.ReadFile(diagnosticFile); err == nil {
				if categories := diagnostics.Categories(data); categories != "" {
					message += " Sanitized categories: " + categories + "."
				}
			}
			return failure{1, message}
		}
	}
	if upkeep.bringUp {
		if err := storage.bringUp(inputs, data); err != nil {
			return failure{70, "Native host bring-up is unconfirmed; keep the service guard and reconcile the original operation. Do not repeat apply."}
		}
	}
	if legacyOperation != nil {
		if err := storage.completeLegacyMaintenance(legacyOperation, inputs, output); err != nil {
			return err
		}
	}
	if operation != nil {
		if err := storage.releaseChecks(data, operation, false, options); err != nil {
			return err
		}
		return operation.finish(storage.ctx, data)
	}
	return nil
}
