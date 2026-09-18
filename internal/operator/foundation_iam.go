package operator

import (
	"context"
	"errors"
	"slices"
	"strings"
)

type foundationBinding struct{ scope, target, role, member string }

func (f foundation) temporary(parent projectParent) []foundationBinding {
	bindings := []foundationBinding{
		{"projects", f.workload, "roles/owner", f.member},
		{"billing accounts", f.billing, "roles/billing.user", f.member},
	}
	if parent.Type != "" {
		scope := "organizations"
		if parent.Type == "folder" {
			scope = "resource-manager folders"
		}
		bindings = append(bindings, foundationBinding{scope, parent.ID, "roles/resourcemanager.projectCreator", f.member})
	}
	return bindings
}

func (f foundation) standing() []foundationBinding {
	return []foundationBinding{
		{"billing accounts", f.billing, "roles/billing.costsManager", f.member},
		{"billing accounts", f.billing, "roles/billing.viewer", f.planMember},
	}
}

func (f foundation) has(ctx context.Context, binding foundationBinding, unconditional bool) (bool, error) {
	var policy struct {
		Bindings []struct {
			Role      string
			Members   []string
			Condition any
		}
	}
	if err := f.decode(ctx, &policy, "gcloud", append(strings.Fields(binding.scope), "get-iam-policy", binding.target, "--format=json")...); err != nil {
		return false, err
	}
	for _, entry := range policy.Bindings {
		if entry.Role == binding.role && slices.Contains(entry.Members, binding.member) && (!unconditional || entry.Condition == nil) {
			return true, nil
		}
	}
	return false, nil
}

func (f foundation) change(ctx context.Context, binding foundationBinding, action string) error {
	args := append(strings.Fields(binding.scope), action+"-iam-policy-binding", binding.target, "--member="+binding.member, "--role="+binding.role)
	if binding.scope != "billing accounts" {
		args = append(args, "--condition=None")
	}
	_, err := f.text(ctx, "gcloud", append(args, "--format=none")...)
	return err
}

func (f foundation) ensure(ctx context.Context, binding foundationBinding, present bool) error {
	exists, err := f.has(ctx, binding, true)
	if err != nil || exists == present {
		return err
	}
	action := "remove"
	if present {
		action = "add"
	}
	return f.change(ctx, binding, action)
}

func (f foundation) finish(ctx context.Context, parent projectParent) error {
	temporary := f.temporary(parent)
	for _, binding := range temporary {
		if err := f.ensure(ctx, binding, false); err != nil {
			return err
		}
	}
	// Re-read after removal, including conditional grants, before publishing readiness.
	for i, binding := range append(temporary, f.standing()...) {
		present, err := f.has(ctx, binding, false)
		if err != nil {
			return err
		}
		if present != (i >= len(temporary)) {
			return errors.New("foundation IAM cleanup or standing billing boundary is incomplete")
		}
	}
	if _, err := f.text(ctx, "gh", "variable", "set", "GCP_WORKLOAD_PROJECT_ID", "--repo", "a-novel/infra", "--body", f.workload); err != nil {
		return err
	}
	published, err := f.text(ctx, "gh", "variable", "get", "GCP_WORKLOAD_PROJECT_ID", "--repo", "a-novel/infra")
	if err != nil {
		return err
	}
	if published != f.workload {
		return errors.New("published workload project coordinate is incorrect")
	}
	return nil
}
