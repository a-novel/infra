package custody

import (
	"context"
	jsonv2 "encoding/json/v2"
	"io"
	"os"
	"regexp"
	"slices"
	"strings"
	"time"

	resourcemanager "google.golang.org/api/cloudresourcemanager/v3"
	"google.golang.org/api/option"
)

var (
	projectPattern       = regexp.MustCompile(`^[a-z][a-z0-9-]{4,28}[a-z0-9]$`)
	projectNumberPattern = regexp.MustCompile(`^[1-9][0-9]{0,19}$`)
)

// projectDeletion is shared by both recovery paths. Resource Manager owns the
// teardown; management-plane state and receipts are deliberately not destroyed.
type projectDeletion struct {
	Project string `json:"project"`
	Number  string `json:"number"`
}

func (target projectDeletion) check(ctx context.Context, client *resourcemanager.Service, state string) error {
	if !projectPattern.MatchString(target.Project) || !projectNumberPattern.MatchString(target.Number) {
		return failure{65, "Invalid disposable project identity."}
	}
	project, err := client.Projects.Get("projects/" + target.Number).Context(ctx).Do()
	if err != nil || project == nil || project.ProjectId != target.Project || project.Name != "projects/"+target.Number || project.State != state || project.IsManagementProject {
		return failure{70, "Exact project lifecycle could not be verified; never repeat deletion on uncertainty."}
	}
	for key, value := range map[string]string{"application": "agora", "environment": "production", "managed-by": "opentofu", "plane": "workload", "recovery": "true"} {
		if project.Labels[key] != value {
			return failure{77, "Target lacks the required disposable recovery labels."}
		}
	}
	return nil
}

func (target projectDeletion) authorize(ctx context.Context, client *resourcemanager.Service, management string) error {
	if err := target.check(ctx, client, "ACTIVE"); err != nil {
		return err
	}
	policy, err := client.Projects.GetIamPolicy("projects/"+target.Number, &resourcemanager.GetIamPolicyRequest{
		Options: &resourcemanager.GetPolicyOptions{RequestedPolicyVersion: 3},
	}).Context(ctx).Do()
	if err != nil || policy == nil {
		return failure{77, "Recovery Project Deleter policy unavailable."}
	}
	for _, binding := range policy.Bindings {
		if binding.Role == "roles/resourcemanager.projectDeleter" && binding.Condition == nil &&
			slices.Contains(binding.Members, "serviceAccount:infra-recovery@"+management+".iam.gserviceaccount.com") {
			return nil
		}
	}
	return failure{77, "Exact unconditional recovery Project Deleter binding is absent."}
}

func (target projectDeletion) dispatch(ctx context.Context, client *resourcemanager.Service) error {
	// Do sends once: never retry an unacknowledged destructive request.
	if _, err := client.Projects.Delete("projects/" + target.Number).Context(ctx).Do(); err != nil {
		return failure{70, "Project deletion outcome uncertain; inspect without repeating the request."}
	}
	return target.observe(ctx, client)
}

func (target projectDeletion) observe(ctx context.Context, client *resourcemanager.Service) error {
	for attempt := 0; attempt < 12; attempt++ {
		if err := target.check(ctx, client, "DELETE_REQUESTED"); err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(5 * time.Second):
		}
	}
	return failure{70, "Deletion-requested is not confirmed; retain evidence and reconcile without replay."}
}

func (custody store) legacyCleanup(args []string, getenv func(string) string, options []option.ClientOption) error {
	if len(args) != 4 {
		return failure{64, "Usage: infra custody recovery cleanup-project <state-bucket> <project> <receipt> <authorization> <confirmation>"}
	}
	project, receipt := args[0], args[1]
	if !projectPattern.MatchString(project) || !sequencePattern.MatchString(receipt) || args[3] != "DELETE "+project {
		return failure{65, "Invalid cleanup target or confirmation."}
	}
	var authorization struct {
		SchemaVersion int    `json:"schemaVersion"`
		Project       string `json:"replacementProject"`
		Receipt       string `json:"sourceReceipt"`
		Revoked       bool   `json:"crossProjectAccessRevoked"`
	}
	data, err := os.ReadFile(args[2])
	if err != nil || decodeRecord(data, &authorization) != nil || authorization.SchemaVersion != 1 ||
		authorization.Project != project || authorization.Receipt != receipt || !authorization.Revoked {
		return failure{77, "Committed cleanup authorization does not match the selected target."}
	}
	management, err := cleanupBoundary(project, getenv)
	if err != nil {
		return err
	}
	if err := custody.cleanupLabel(getenv); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(custody.ctx, 2*time.Minute)
	defer cancel()
	client, err := resourcemanager.NewService(ctx, options...)
	if err != nil {
		return err
	}
	metadata, err := client.Projects.Get("projects/" + project).Context(ctx).Do()
	if err != nil || metadata == nil || metadata.ProjectId != project {
		return failure{70, "Disposable project identity unavailable."}
	}
	target := projectDeletion{project, strings.TrimPrefix(metadata.Name, "projects/")}
	if err := target.authorize(ctx, client, management); err != nil {
		return err
	}
	return target.dispatch(ctx, client)
}

func (custody store) cleanupLabel(getenv func(string) string) error {
	if getenv("GITHUB_REPOSITORY") != "a-novel/infra" || !commitPattern.MatchString(getenv("GITHUB_SHA")) {
		return failure{65, "Invalid cleanup commit identity."}
	}
	if err := custody.execute(custody.ctx, io.Discard, "./ops/verify-deletion-label.sh", "a-novel/infra", getenv("GITHUB_SHA")); err != nil {
		return failure{77, "Merged-commit resource deletion approval is required."}
	}
	return nil
}

func cleanupBoundary(project string, getenv func(string) string) (string, error) {
	var foundation struct {
		Management string            `json:"management_project_id"`
		Workload   string            `json:"workload_project_id"`
		Public     string            `json:"public_project_id"`
		Services   map[string]string `json:"service_projects"`
	}
	invalid := failure{77, "Cleanup cannot target a management, workload or service project."}
	if jsonv2.Unmarshal([]byte(getenv("FOUNDATION_CONFIG")), &foundation) != nil {
		return "", invalid
	}
	protected := []string{foundation.Management, foundation.Workload}
	if foundation.Public != "" {
		protected = append(protected, foundation.Public)
	}
	for _, service := range foundation.Services {
		protected = append(protected, service)
	}
	for _, target := range protected {
		if !projectPattern.MatchString(target) || target == project {
			return "", invalid
		}
	}
	return foundation.Management, nil
}
