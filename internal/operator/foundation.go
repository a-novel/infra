package operator

import (
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/netip"
	"slices"
	"strings"
	"unicode"
)

type projectParent struct{ Type, ID string }

type foundationOptions struct {
	command, name, region, zone, subnet, costEmail, operationsEmail string
	parent                                                          *projectParent
	adopt                                                           bool
	databaseOperators, initializers                                 []string
	serviceProjects                                                 map[string]string
}

type foundation struct {
	management, workload, member, planMember, billing string
	execute                                           func(context.Context, io.Reader, string, ...string) ([]byte, error)
}

// Foundation runs human-owned setup and cleanup. execute must pass literal
// arguments, disable cloud prompts, and keep child output and errors private.
// Protected configuration reaches gh only through its input reader.
func Foundation(ctx context.Context, args []string, getenv func(string) string, execute func(context.Context, io.Reader, string, ...string) ([]byte, error), stdout, stderr io.Writer) int {
	stop := func(code int, err error) int {
		_, _ = fmt.Fprintln(stderr, "FAIL", err) // Diagnostics are best effort.
		return code
	}
	options, err := foundationFlags(args, getenv)
	if err != nil {
		return stop(64, err)
	}
	projects, err := projectIDs(getenv)
	if err != nil {
		return stop(64, err)
	}
	f := foundation{management: projects["GCP_MANAGEMENT_PROJECT_ID"], workload: projects["GCP_WORKLOAD_PROJECT_ID"], execute: execute}
	// Emergency revocation must remain usable from a stale or dirty checkout.
	if options.command != "revoke-audit-access" {
		if err := f.reviewed(ctx); err != nil {
			return stop(65, err)
		}
	}
	if err := f.setup(ctx, options, getenv); err != nil {
		return stop(70, err)
	}
	if _, err := fmt.Fprintln(stdout, "PASS foundation", options.command); err != nil {
		return stop(70, errors.New("cannot write foundation result"))
	}
	return 0
}

func foundationFlags(args []string, getenv func(string) string) (foundationOptions, error) {
	o := foundationOptions{}
	usage := errors.New("usage: infra foundation-setup <configure|grant|grant-audit-access|revoke-audit-access|finish> [options]; see the workload foundation runbook")
	if len(args) == 0 || !slices.Contains([]string{"configure", "grant", "grant-audit-access", "revoke-audit-access", "finish"}, args[0]) {
		return o, usage
	}
	o.command = args[0]
	serviceProjects := getenv("INFRA_SERVICE_PROJECTS")
	flags := flag.NewFlagSet("foundation-setup", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	if o.command == "configure" || o.command == "grant" || o.command == "finish" {
		parent := func(kind, id string) error {
			if o.parent != nil || kind != "" && !matches(`[0-9]+`, id) {
				return errors.New("choose one valid project parent")
			}
			o.parent = &projectParent{Type: kind, ID: id}
			return nil
		}
		flags.Func("organization-id", "Workload organization ID", func(id string) error { return parent("organization", id) })
		flags.Func("folder-id", "Workload folder ID", func(id string) error { return parent("folder", id) })
		flags.BoolFunc("standalone", "Use a parentless project", func(value string) error {
			if value != "true" {
				return usage
			}
			return parent("", "")
		})
	}
	if o.command == "configure" || o.command == "grant" {
		flags.StringVar(&o.name, "workload-project-name", "Agora production", "Workload display name")
		flags.BoolVar(&o.adopt, "adopt-existing-project", false, "Adopt the exact existing workload project")
	}
	if o.command == "configure" {
		flags.StringVar(&serviceProjects, "service-projects", serviceProjects, "JSON object mapping service names to project IDs; use {} for none")
		flags.StringVar(&o.region, "region", cmp.Or(getenv("INFRA_REGION"), "europe-west1"), "Workload region")
		flags.StringVar(&o.zone, "database-zone", getenv("INFRA_DATABASE_ZONE"), "Database zone")
		flags.StringVar(&o.subnet, "subnet-cidr", "10.20.0.0/24", "Private /24 subnet")
		flags.StringVar(&o.costEmail, "cost-alert-email", getenv("INFRA_COST_ALERT_EMAIL"), "Cost alert recipient")
		flags.StringVar(&o.operationsEmail, "operations-alert-email", getenv("INFRA_OPERATIONS_ALERT_EMAIL"), "Operations alert recipient")
		flags.Func("database-operator-principal", "Repeatable human IAM principal", func(value string) error { o.databaseOperators = append(o.databaseOperators, value); return nil })
		flags.Func("auth-initializer-principal", "Repeatable initializer IAM principal", func(value string) error { o.initializers = append(o.initializers, value); return nil })
	}
	if flags.Parse(args[1:]) != nil || flags.NArg() != 0 {
		return o, usage
	}
	if (o.command == "configure" || o.command == "grant") && (o.name == "" || len([]rune(o.name)) > 30 || strings.ContainsFunc(o.name, unicode.IsControl)) {
		return o, errors.New("workload project name is invalid")
	}
	if o.command == "configure" {
		if json.Unmarshal([]byte(serviceProjects), &o.serviceProjects) != nil || o.serviceProjects == nil {
			return o, errors.New("service projects must be a JSON object; load the reviewed .envrc or pass --service-projects")
		}
		o.zone = cmp.Or(o.zone, o.region+"-c")
		prefix, err := netip.ParsePrefix(o.subnet)
		if !matches(`[a-z]+-[a-z]+[0-9]+`, o.region) || !strings.HasPrefix(o.zone, o.region+"-") || err != nil || !prefix.Addr().Is4() || prefix.Bits() != 24 || prefix != prefix.Masked() || prefix.Addr().As4()[0] != 10 {
			return o, errors.New("region, database zone, or private /24 subnet is invalid")
		}
	}
	return o, nil
}

func (f foundation) text(ctx context.Context, name string, args ...string) (string, error) {
	data, err := f.execute(ctx, nil, name, args...)
	if err != nil {
		return "", fmt.Errorf("%s %s failed; inspect the operation before retrying", name, args[0])
	}
	return strings.TrimSpace(string(data)), nil
}

func (f foundation) decode(ctx context.Context, target any, name string, args ...string) error {
	data, err := f.text(ctx, name, args...)
	if err != nil {
		return err
	}
	if json.Unmarshal([]byte(data), target) != nil || data == "null" {
		return errors.New("invalid foundation inspection response")
	}
	return nil
}

func (f foundation) reviewed(ctx context.Context) error {
	for _, check := range []struct {
		args     []string
		expected string
	}{
		{[]string{"branch", "--show-current"}, "master"}, {[]string{"status", "--porcelain"}, ""},
	} {
		value, err := f.text(ctx, "git", check.args...)
		if err != nil || value != check.expected {
			return errors.New("this mutation requires a clean local master checkout")
		}
	}
	local, err := f.text(ctx, "git", "rev-parse", "HEAD")
	if err != nil {
		return err
	}
	remote, err := f.text(ctx, "gh", "api", "repos/a-novel/infra/commits/master", "--jq", ".sha")
	if err != nil {
		return err
	}
	if !matches(`[a-f0-9]{40}`, local) || local != remote {
		return errors.New("local master does not equal remote master")
	}
	return nil
}

func (f *foundation) setup(ctx context.Context, o foundationOptions, getenv func(string) string) error {
	if strings.HasSuffix(o.command, "audit-access") {
		account, err := f.account(ctx)
		if err != nil {
			return err
		}
		binding := foundationBinding{"projects", f.workload, "roles/iam.securityReviewer", "user:" + account}
		return f.ensure(ctx, binding, o.command == "grant-audit-access")
	}
	published, err := f.text(ctx, "gh", "variable", "get", "GCP_MANAGEMENT_PROJECT_ID", "--repo", "a-novel/infra")
	if err != nil {
		return err
	}
	if published != f.management {
		return errors.New("management project does not match the published coordinate")
	}
	f.member = "serviceAccount:infra-foundation@" + f.management + ".iam.gserviceaccount.com"
	f.planMember = "serviceAccount:infra-plan@" + f.management + ".iam.gserviceaccount.com"
	f.billing, err = f.text(ctx, "gcloud", "billing", "projects", "describe", f.management, "--format=value(billingAccountName.basename())")
	if err != nil {
		return err
	}
	if !matches(`[0-9A-Z]{6}-[0-9A-Z]{6}-[0-9A-Z]{6}`, f.billing) {
		return errors.New("management billing account is invalid")
	}
	if o.parent == nil || o.command == "finish" {
		project := f.management
		if o.command == "finish" {
			project = f.workload
		}
		var detected struct{ Parent projectParent }
		if err := f.decode(ctx, &detected, "gcloud", "projects", "describe", project, "--format=json"); err != nil {
			return err
		}
		if o.parent != nil && *o.parent != detected.Parent {
			return errors.New("explicit parent does not match the workload project parent")
		}
		o.parent = &detected.Parent
	}
	p := *o.parent
	if p != (projectParent{}) && (!slices.Contains([]string{"organization", "folder"}, p.Type) || !matches(`[0-9]+`, p.ID)) {
		return errors.New("project parent is invalid")
	}
	if p.Type == "" && !o.adopt && o.command != "finish" {
		return errors.New("standalone provisioning requires --adopt-existing-project")
	}
	switch o.command {
	case "configure":
		return f.configure(ctx, o, getenv)
	case "grant":
		return f.grant(ctx, o)
	default:
		return f.finish(ctx, p)
	}
}

func (f foundation) account(ctx context.Context) (string, error) {
	account, err := f.text(ctx, "gcloud", "config", "get-value", "account")
	if err != nil {
		return "", err
	}
	if !matches(`[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+`, account) {
		return "", errors.New("active Google account is invalid")
	}
	return account, nil
}

func (f foundation) configure(ctx context.Context, o foundationOptions, getenv func(string) string) error {
	bucket, err := f.text(ctx, "gh", "variable", "get", "GCP_BACKUP_BUCKET", "--repo", "a-novel/infra")
	if err != nil {
		return err
	}
	if !matches(`[a-z0-9][a-z0-9._-]{1,221}[a-z0-9]`, bucket) {
		return errors.New("backup bucket coordinate is invalid")
	}
	account, err := f.account(ctx)
	if err != nil {
		return err
	}
	config := map[string]any{
		"management_project_id": f.management, "workload_project_id": f.workload, "workload_project_name": o.name,
		"backup_bucket_name": bucket, "billing_account_id": f.billing, "organization_id": nil, "folder_id": nil,
		"region": o.region, "database_zone": o.zone, "subnet_cidr": o.subnet, "adopt_existing_project": o.adopt,
		"service_projects": o.serviceProjects,
	}
	if o.parent.Type != "" {
		config[o.parent.Type+"_id"] = o.parent.ID
	}
	for field, value := range map[string]string{"cost_alert_email": cmp.Or(o.costEmail, account), "operations_alert_email": cmp.Or(o.operationsEmail, account)} {
		if !matches(`[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+`, value) {
			return errors.New("alert email is invalid")
		}
		config[field] = value
	}
	for _, principals := range []struct {
		field, env string
		values     []string
	}{
		{"database_operator_principals", "INFRA_DATABASE_OPERATOR_PRINCIPALS", o.databaseOperators},
		{"authentication_initializer_principals", "INFRA_AUTH_INITIALIZER_PRINCIPALS", o.initializers},
	} {
		values := principals.values
		if len(values) == 0 {
			values = strings.Fields(getenv(principals.env))
		}
		if len(values) == 0 {
			values = []string{"user:" + account}
		}
		for _, value := range values {
			if !matches(`(user|group):[^[:space:]@]+@[^[:space:]@]+`, value) {
				return errors.New("operator principal is invalid")
			}
		}
		config[principals.field] = values
	}
	var environment struct {
		Name   string
		Branch struct {
			Protected bool  `json:"protected_branches"`
			Custom    *bool `json:"custom_branch_policies"`
		} `json:"deployment_branch_policy"`
		Rules []struct{ Type string } `json:"protection_rules"`
	}
	if err := f.decode(ctx, &environment, "gh", "api", "repos/a-novel/infra/environments/production-foundation"); err != nil {
		return err
	}
	if environment.Name != "production-foundation" || !environment.Branch.Protected || environment.Branch.Custom == nil || *environment.Branch.Custom || !slices.ContainsFunc(environment.Rules, func(rule struct{ Type string }) bool { return rule.Type == "required_reviewers" }) {
		return errors.New("production-foundation environment protection is incomplete")
	}
	data, err := json.Marshal(config)
	if err != nil {
		return err
	}
	for _, destination := range []string{"production-foundation", "production-recovery"} {
		if _, err := f.execute(ctx, bytes.NewReader(data), "gh", "secret", "set", "FOUNDATION_TFVARS_JSON", "--repo", "a-novel/infra", "--env", destination); err != nil {
			return fmt.Errorf("configuration publication failed for %s; inspect before retrying", destination)
		}
	}
	return nil
}

func (f foundation) grant(ctx context.Context, o foundationOptions) error {
	if o.adopt {
		var project struct {
			ProjectID, LifecycleState string
			Parent                    projectParent
		}
		data, err := f.text(ctx, "gcloud", "projects", "describe", f.workload, "--format=json")
		if err != nil {
			if o.parent.Type != "" {
				return err
			}
			if _, err := f.text(ctx, "gcloud", "projects", "create", f.workload, "--name="+o.name, "--set-as-default=false"); err != nil {
				return err
			}
			data, err = f.text(ctx, "gcloud", "projects", "describe", f.workload, "--format=json")
			if err != nil {
				return err
			}
		}
		if json.Unmarshal([]byte(data), &project) != nil || project.ProjectID != f.workload || project.LifecycleState != "ACTIVE" || project.Parent != *o.parent {
			return errors.New("adopted project identity or parent is unexpected")
		}
		var billing struct {
			BillingEnabled     bool
			BillingAccountName string
		}
		if err := f.decode(ctx, &billing, "gcloud", "billing", "projects", "describe", f.workload, "--format=json"); err != nil {
			return err
		}
		if billing.BillingEnabled && billing.BillingAccountName != "billingAccounts/"+f.billing {
			return errors.New("adopted project uses a different billing account")
		}
		if !billing.BillingEnabled && o.parent.Type == "" {
			if _, err := f.text(ctx, "gcloud", "billing", "projects", "link", f.workload, "--billing-account="+f.billing, "--format=none"); err != nil {
				return err
			}
		}
	}
	bindings := f.temporary(*o.parent)
	// Establish project creation authority before granting project and billing access.
	if o.parent.Type != "" {
		bindings = append(bindings[2:], bindings[:2]...)
	}
	for _, binding := range append(bindings, f.standing()...) {
		if binding.role == "roles/owner" && !o.adopt {
			continue
		}
		if err := f.change(ctx, binding, "add"); err != nil {
			return err
		}
	}
	return nil
}
