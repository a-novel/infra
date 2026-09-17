package operator_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"slices"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/operator"
)

const (
	foundationMember      = "serviceAccount:infra-foundation@management-project-prod.iam.gserviceaccount.com"
	planMember            = "serviceAccount:infra-plan@management-project-prod.iam.gserviceaccount.com"
	workloadInspection    = "gcloud projects describe workload-project-prod --format=json"
	environmentInspection = "gh api repos/a-novel/infra/environments/production-foundation"
)

type foundationFixture struct {
	env              map[string]string
	replies          map[string][]string
	calls, mutations []string
	secrets          [][]byte
	failure          string
}

func foundationCase() *foundationFixture {
	return &foundationFixture{
		env: map[string]string{"INFRA_MANAGEMENT_PROJECT_ID": "management-project-prod", "INFRA_WORKLOAD_PROJECT_ID": "workload-project-prod", "INFRA_REGION": "europe-west1", "INFRA_DATABASE_ZONE": "europe-west1-d"},
		replies: map[string][]string{
			"git branch --show-current": {"master"}, "git status --porcelain": {""},
			"git rev-parse HEAD": {strings.Repeat("a", 40)}, "gh api repos/a-novel/infra/commits/master --jq .sha": {strings.Repeat("a", 40)},
			"gh variable get GCP_MANAGEMENT_PROJECT_ID --repo a-novel/infra":                                         {"management-project-prod"},
			"gh variable get GCP_BACKUP_BUCKET --repo a-novel/infra":                                                 {"fixture-backups"},
			"gcloud billing projects describe management-project-prod --format=value(billingAccountName.basename())": {"ABCDEF-123456-ABCDEF"},
			"gcloud projects describe management-project-prod --format=json":                                         {`{"parent":{"type":"organization","id":"123"}}`},
			workloadInspection: {`{"projectId":"workload-project-prod","lifecycleState":"ACTIVE","parent":{"type":"folder","id":"456"}}`},
			"gcloud billing projects describe workload-project-prod --format=json": {`{"billingEnabled":true,"billingAccountName":"billingAccounts/ABCDEF-123456-ABCDEF"}`},
			"gcloud config get-value account":                                      {"private@example.com"},
			environmentInspection:                                                  {`{"name":"production-foundation","deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false},"protection_rules":[{"type":"required_reviewers"}]}`},
		},
	}
}

func (f *foundationFixture) run(t *testing.T, args ...string) (int, string) {
	t.Helper()
	var output bytes.Buffer
	code := operator.Foundation(t.Context(), args, func(key string) string { return f.env[key] }, func(_ context.Context, input io.Reader, name string, args ...string) ([]byte, error) {
		line := name + " " + strings.Join(args, " ")
		f.calls = append(f.calls, line)
		reply, ok := f.replies[line]
		require.True(t, ok, "unexpected command: %s", line)
		if strings.Contains(line, "-iam-policy-binding") || strings.Contains(line, " set ") || strings.Contains(line, " projects create ") || strings.Contains(line, " projects link ") {
			f.mutations = append(f.mutations, line)
		}
		if strings.HasPrefix(line, "gh secret set ") {
			require.NotNil(t, input)
			data, err := io.ReadAll(input)
			require.NoError(t, err)
			f.secrets = append(f.secrets, data)
		} else {
			require.Nil(t, input)
		}
		if f.failure == line {
			f.failure = ""
			return []byte("fixture-private-diagnostic"), errors.New("fixture-private-diagnostic")
		}
		if len(reply) > 1 {
			f.replies[line] = reply[1:]
		}
		return []byte(reply[0]), nil
	}, &output, &output)
	require.NotContains(t, output.String(), "private@example.com")
	require.NotContains(t, output.String(), "ABCDEF-123456-ABCDEF")
	require.NotContains(t, output.String(), "fixture-private-diagnostic")
	return code, output.String()
}

func foundationIAM(scope, target, action, member, role string) string {
	command := "gcloud " + scope + " " + action + "-iam-policy-binding " + target + " --member=" + member + " --role=" + role
	if scope != "billing accounts" {
		command += " --condition=None"
	}
	return command + " --format=none"
}

func foundationPolicy(member string, roles ...string) string {
	bindings := []map[string]any{}
	for _, role := range roles {
		bindings = append(bindings, map[string]any{"role": role, "members": []string{member}})
	}
	data, _ := json.Marshal(map[string]any{"bindings": bindings})
	return string(data)
}

func (f *foundationFixture) configuration() []string {
	writes := []string{}
	for _, destination := range []string{"production-foundation", "production-recovery"} {
		command := "gh secret set FOUNDATION_TFVARS_JSON --repo a-novel/infra --env " + destination
		f.replies[command] = []string{""}
		writes = append(writes, command)
	}
	return writes
}

func (f *foundationFixture) cleanup() []string {
	writes := []string{}
	for _, grant := range []struct{ scope, target, role string }{
		{"projects", "workload-project-prod", "roles/owner"},
		{"billing accounts", "ABCDEF-123456-ABCDEF", "roles/billing.user"},
		{"resource-manager folders", "456", "roles/resourcemanager.projectCreator"},
	} {
		policy := foundationPolicy(foundationMember, grant.role)
		final := `{"bindings":[]}`
		if grant.scope == "billing accounts" {
			final = `{"bindings":[{"role":"roles/billing.costsManager","members":["` + foundationMember + `"]},{"role":"roles/billing.viewer","members":["` + planMember + `"]}]}`
		}
		f.replies["gcloud "+grant.scope+" get-iam-policy "+grant.target+" --format=json"] = []string{policy, final}
		command := foundationIAM(grant.scope, grant.target, "remove", foundationMember, grant.role)
		f.replies[command] = []string{""}
		writes = append(writes, command)
	}
	command := "gh variable set GCP_WORKLOAD_PROJECT_ID --repo a-novel/infra --body workload-project-prod"
	f.replies[command] = []string{""}
	f.replies["gh variable get GCP_WORKLOAD_PROJECT_ID --repo a-novel/infra"] = []string{"workload-project-prod"}
	return append(writes, command)
}

func TestFoundation(t *testing.T) {
	t.Parallel()
	t.Run("Configuration", func(t *testing.T) {
		t.Parallel()
		f := foundationCase()
		writes := f.configuration()
		f.env["INFRA_DATABASE_OPERATOR_PRINCIPALS"] = "group:db@example.com user:second@example.com"
		f.env["INFRA_AUTH_INITIALIZER_PRINCIPALS"] = "group:ignored@example.com"
		code, out := f.run(t, "configure", "--auth-initializer-principal", "user:init@example.com")
		require.Zero(t, code, out)
		require.Equal(t, writes, f.mutations)
		require.Len(t, f.secrets, 2)
		require.Equal(t, f.secrets[0], f.secrets[1])
		require.JSONEq(t, `{"management_project_id":"management-project-prod","workload_project_id":"workload-project-prod","workload_project_name":"Agora production","backup_bucket_name":"fixture-backups","billing_account_id":"ABCDEF-123456-ABCDEF","organization_id":"123","folder_id":null,"region":"europe-west1","database_zone":"europe-west1-d","subnet_cidr":"10.20.0.0/24","adopt_existing_project":false,"database_operator_principals":["group:db@example.com","user:second@example.com"],"authentication_initializer_principals":["user:init@example.com"],"cost_alert_email":"private@example.com","operations_alert_email":"private@example.com"}`, string(f.secrets[0]))
	})
	t.Run("CleanupActualParent", func(t *testing.T) {
		t.Parallel()
		f := foundationCase()
		writes := f.cleanup()
		code, out := f.run(t, "finish")
		require.Zero(t, code, out)
		require.Equal(t, writes, f.mutations)
		require.NotContains(t, strings.Join(f.calls, "\n"), "organizations")
	})
	t.Run("Provisioning", func(t *testing.T) {
		t.Parallel()
		for _, tc := range []struct {
			name, scope, target string
			args                []string
			create              bool
		}{
			{"NewOrganization", "organizations", "123", nil, false},
			{"AdoptFolder", "resource-manager folders", "456", []string{"--folder-id", "456", "--adopt-existing-project"}, false},
			{"AdoptStandalone", "", "", []string{"--standalone", "--adopt-existing-project"}, false},
			{"CreateStandalone", "", "", []string{"--standalone", "--adopt-existing-project"}, true},
		} {
			t.Run(tc.name, func(t *testing.T) {
				t.Parallel()
				f := foundationCase()
				var writes []string
				if tc.scope == "" {
					f.replies[workloadInspection] = []string{`{"projectId":"workload-project-prod","lifecycleState":"ACTIVE"}`}
					if tc.create {
						f.failure = workloadInspection
						writes = append(writes, "gcloud projects create workload-project-prod --name=Agora production --set-as-default=false")
						f.replies["gcloud billing projects describe workload-project-prod --format=json"] = []string{`{"billingEnabled":false}`}
						writes = append(writes, "gcloud billing projects link workload-project-prod --billing-account=ABCDEF-123456-ABCDEF --format=none")
					}
				} else {
					writes = append(writes, foundationIAM(tc.scope, tc.target, "add", foundationMember, "roles/resourcemanager.projectCreator"))
				}
				if len(tc.args) > 0 {
					writes = append(writes, foundationIAM("projects", "workload-project-prod", "add", foundationMember, "roles/owner"))
				}
				for _, grant := range []struct{ member, role string }{{foundationMember, "roles/billing.user"}, {foundationMember, "roles/billing.costsManager"}, {planMember, "roles/billing.viewer"}} {
					writes = append(writes, foundationIAM("billing accounts", "ABCDEF-123456-ABCDEF", "add", grant.member, grant.role))
				}
				for _, command := range writes {
					f.replies[command] = []string{""}
				}
				code, out := f.run(t, append([]string{"grant"}, tc.args...)...)
				require.Zero(t, code, out)
				require.Equal(t, writes, f.mutations)
			})
		}
	})
	t.Run("RejectBeforeMutation", func(t *testing.T) {
		t.Parallel()
		for _, tc := range []struct {
			name, command, reply, value string
			args                        []string
		}{
			{"Dirty", "configure", "git status --porcelain", " M file", nil},
			{"Stale", "configure", "gh api repos/a-novel/infra/commits/master --jq .sha", strings.Repeat("b", 40), nil},
			{"Management", "configure", "gh variable get GCP_MANAGEMENT_PROJECT_ID --repo a-novel/infra", "wrong-project", nil},
			{"Parent", "finish", workloadInspection, `{"parent":{"type":"folder","id":"456"}}`, []string{"--organization-id", "123"}},
			{"MalformedParent", "configure", "gcloud projects describe management-project-prod --format=json", `{"parent":{"id":"123"}}`, nil},
			{"Protection", "configure", environmentInspection, `{"name":"production-foundation","deployment_branch_policy":{"protected_branches":true},"protection_rules":[{"type":"required_reviewers"}]}`, nil},
			{"AdoptIdentity", "grant", workloadInspection, `{"projectId":"other-project","lifecycleState":"ACTIVE","parent":{"type":"folder","id":"456"}}`, []string{"--folder-id", "456", "--adopt-existing-project"}},
			{"AdoptBilling", "grant", "gcloud billing projects describe workload-project-prod --format=json", `{"billingEnabled":true,"billingAccountName":"billingAccounts/OTHER"}`, []string{"--folder-id", "456", "--adopt-existing-project"}},
			{"Standalone", "grant", workloadInspection, `{"projectId":"workload-project-prod","lifecycleState":"ACTIVE","parent":{"type":"folder","id":"456"}}`, []string{"--standalone", "--adopt-existing-project"}},
			{"MalformedStandalone", "grant", workloadInspection, `{`, []string{"--standalone", "--adopt-existing-project"}},
		} {
			t.Run(tc.name, func(t *testing.T) {
				t.Parallel()
				f := foundationCase()
				f.replies[tc.reply] = []string{tc.value}
				code, _ := f.run(t, append([]string{tc.command}, tc.args...)...)
				require.NotZero(t, code)
				require.Empty(t, f.mutations)
			})
		}
	})
	t.Run("UnverifiedCleanup", func(t *testing.T) {
		t.Parallel()
		for _, remaining := range []string{
			`{"bindings":[{"role":"roles/owner","members":["` + foundationMember + `"]}]}`,
			`{"bindings":[{"role":"roles/owner","members":["` + foundationMember + `"],"condition":{"expression":"true"}}]}`,
			`{"bindings":`,
		} {
			f := foundationCase()
			f.cleanup()
			f.replies["gcloud projects get-iam-policy workload-project-prod --format=json"][1] = remaining
			code, _ := f.run(t, "finish")
			require.NotZero(t, code)
			require.Len(t, f.mutations, 3)
		}
		f := foundationCase()
		f.cleanup()
		f.replies["gcloud billing accounts get-iam-policy ABCDEF-123456-ABCDEF --format=json"][1] = `{"bindings":[]}`
		code, _ := f.run(t, "finish")
		require.NotZero(t, code)
		require.Len(t, f.mutations, 3)
	})
	t.Run("StopOnMutationFailure", func(t *testing.T) {
		t.Parallel()
		for _, command := range []string{"configure", "finish"} {
			baseline := foundationCase()
			writes := baseline.configuration()
			if command == "finish" {
				writes = baseline.cleanup()
			}
			for _, failure := range writes {
				f := foundationCase()
				f.configuration()
				f.cleanup()
				f.failure = failure
				code, _ := f.run(t, command)
				require.NotZero(t, code)
				require.Equal(t, failure, f.calls[len(f.calls)-1])
			}
		}
	})
	t.Run("AuditRevocationWithoutSetup", func(t *testing.T) {
		t.Parallel()
		f := foundationCase()
		f.replies["git status --porcelain"] = []string{" M file"}
		f.replies["gcloud projects get-iam-policy workload-project-prod --format=json"] = []string{foundationPolicy("user:private@example.com", "roles/iam.securityReviewer")}
		remove := foundationIAM("projects", "workload-project-prod", "remove", "user:private@example.com", "roles/iam.securityReviewer")
		f.replies[remove] = []string{""}
		code, out := f.run(t, "revoke-audit-access")
		require.Zero(t, code, out)
		require.Equal(t, []string{remove}, f.mutations)
		require.False(t, slices.ContainsFunc(f.calls, func(call string) bool {
			return strings.Contains(call, "billing") || strings.HasPrefix(call, "git ") || strings.HasPrefix(call, "gh ")
		}))
	})
	t.Run("Arguments", func(t *testing.T) {
		t.Parallel()
		for _, args := range [][]string{nil, {"unknown"}, {"finish", "--region", "europe-west1"}, {"configure", "--folder-id", "123", "--folder-id", "123"}, {"configure", "--folder-id", "123", "--standalone"}, {"configure", "--subnet-cidr", "8.8.8.0/24"}, {"configure", "--subnet-cidr", "10.20.0.1/24"}, {"configure", "--region", "europe-west2"}, {"configure", "--cost-alert-email"}, {"configure", "unexpected"}} {
			f := foundationCase()
			code, _ := f.run(t, args...)
			require.Equal(t, 64, code)
			require.Empty(t, f.calls)
		}
	})
}
