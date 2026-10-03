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
		env: map[string]string{"INFRA_MANAGEMENT_PROJECT_ID": "management-project-prod", "INFRA_WORKLOAD_PROJECT_ID": "workload-project-prod", "INFRA_SERVICE_PROJECTS": "{}", "INFRA_PGBACKREST_REPOSITORY_SERVICES": "[]", "INFRA_REGION": "europe-west1", "INFRA_DATABASE_ZONE": "europe-west1-d"},
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
	t.Run("ReleaseZones", func(t *testing.T) {
		t.Parallel()
		for _, tc := range []struct {
			name, value, flag, public, shared, projects, repository, retirement string
			valid                                                               bool
		}{
			{name: "Disabled", valid: true},
			{name: "Empty", value: "{}", valid: true},
			{name: "Private", value: `{"json-keys":["private"],"authentication":["private"]}`, shared: "true", valid: true},
			{name: "Split", value: `{"json-keys":["private","public-api"],"authentication":["public-api"]}`, shared: "true", public: "agora-api-test", valid: true},
			{name: "PlatformServiceRejected", value: `{"json-keys":["public"]}`, shared: "true", public: "agora-api-test"},
			{name: "Flag", value: "invalid", flag: `{"json-keys":["private"]}`, shared: "true", valid: true},
			{name: "DisableFlag", value: `{"json-keys":["private"]}`, flag: "{}", valid: true},
			{name: "Malformed", value: "private-invalid-json"},
			{name: "Null", value: "null"},
			{name: "Array", value: "[]"},
			{name: "NullZones", value: `{"json-keys":null}`, shared: "true"},
			{name: "EmptyZones", value: `{"json-keys":[]}`, shared: "true"},
			{name: "ScalarZone", value: `{"json-keys":"private"}`, shared: "true"},
			{name: "UnknownService", value: `{"peer":["private"]}`, shared: "true"},
			{name: "UnknownZone", value: `{"json-keys":["admin"]}`, shared: "true"},
			{name: "Duplicate", value: `{"json-keys":["private","private"]}`, shared: "true"},
			{name: "TooMany", value: `{"json-keys":["private","public","private"]}`, shared: "true"},
			{name: "MissingAPI", value: `{"json-keys":["public-api"]}`, shared: "true"},
			{name: "MissingHost", value: `{"json-keys":["private"]}`},
			{name: "Dedicated", value: `{"json-keys":["private"]}`, shared: "true", projects: `{"json-keys":"agora-json-keys-test"}`},
			{name: "NativeRepository", value: `{"json-keys":["private"]}`, shared: "true", repository: `["json-keys"]`},
			{name: "Retirement", value: `{"json-keys":["private"]}`, shared: "true", retirement: "true"},
		} {
			t.Run(tc.name, func(t *testing.T) {
				t.Parallel()
				f := foundationCase()
				writes := f.configuration()
				f.env["INFRA_SERVICE_RELEASE_ZONES"] = tc.value
				f.env["INFRA_PUBLIC_API_PROJECT_ID"], f.env["INFRA_SHARED_VPC_ENABLED"] = tc.public, tc.shared
				f.env["INFRA_RETIRE_JSON_KEYS_PROJECT"] = tc.retirement
				for key, value := range map[string]string{"INFRA_SERVICE_PROJECTS": tc.projects, "INFRA_PGBACKREST_REPOSITORY_SERVICES": tc.repository} {
					if value != "" {
						f.env[key] = value
					}
				}
				args, expected := []string{"configure"}, tc.value
				if tc.flag != "" {
					args, expected = append(args, "--service-release-zones", tc.flag), tc.flag
				}
				code, out := f.run(t, args...)
				require.NotContains(t, out, "private-invalid-json")
				if !tc.valid {
					require.Equal(t, 64, code, out)
					require.Empty(t, f.calls)
					return
				}
				require.Zero(t, code, out)
				require.Equal(t, writes, f.mutations)
				require.Len(t, f.secrets, 2)
				require.Equal(t, f.secrets[0], f.secrets[1])
				var config map[string]json.RawMessage
				require.NoError(t, json.Unmarshal(f.secrets[0], &config))
				if expected == "" || expected == "{}" {
					require.NotContains(t, config, "service_release_zones")
				} else {
					require.JSONEq(t, expected, string(config["service_release_zones"]))
				}
			})
		}
	})
	t.Run("TrustZones", func(t *testing.T) {
		t.Parallel()
		for _, tc := range []struct {
			name, public, shared, services, retirement string
			args                                       []string
			valid                                      bool
		}{
			{"Disabled", "", "", "{}", "", nil, true},
			{"RetainHost", "", "true", "{}", "", nil, true},
			{"Public", "agora-public-test", "true", "{}", "", nil, true},
			{"Explicit", "", "", "{}", "", []string{"--shared-vpc-enabled", "--public-project-id=agora-public-test"}, true},
			{"Management", "management-project-prod", "true", "{}", "", nil, false},
			{"Workload", "workload-project-prod", "true", "{}", "", nil, false},
			{"InvalidID", "INVALID", "true", "{}", "", nil, false},
			{"NoHost", "agora-public-test", "false", "{}", "", nil, true},
			{"MalformedHost", "", "yes", "{}", "", nil, false},
			{"DedicatedService", "agora-public-test", "true", `{"json-keys":"json-keys-project-prod"}`, "", nil, false},
			{"Retirement", "agora-public-test", "true", "{}", "true", nil, false},
		} {
			t.Run(tc.name, func(t *testing.T) {
				t.Parallel()
				f := foundationCase()
				writes := f.configuration()
				f.env["INFRA_PUBLIC_PROJECT_ID"], f.env["INFRA_SHARED_VPC_ENABLED"] = tc.public, tc.shared
				f.env["INFRA_SERVICE_PROJECTS"], f.env["INFRA_RETIRE_JSON_KEYS_PROJECT"] = tc.services, tc.retirement
				code, out := f.run(t, append([]string{"configure"}, tc.args...)...)
				if !tc.valid {
					require.Equal(t, 64, code, out)
					require.Empty(t, f.calls)
					return
				}
				require.Zero(t, code, out)
				require.Equal(t, writes, f.mutations)
				require.Len(t, f.secrets, 2)
				require.Equal(t, f.secrets[0], f.secrets[1])
				var config map[string]any
				require.NoError(t, json.Unmarshal(f.secrets[0], &config))
				if tc.name == "Disabled" {
					require.NotContains(t, config, "shared_vpc_enabled")
					require.NotContains(t, config, "public_project_id")
				} else {
					if tc.name == "NoHost" {
						require.NotContains(t, config, "shared_vpc_enabled")
					} else {
						require.Equal(t, true, config["shared_vpc_enabled"])
					}
					if tc.name != "RetainHost" {
						require.Equal(t, "agora-public-test", config["public_project_id"])
					} else {
						require.NotContains(t, config, "public_project_id")
					}
				}
				require.Equal(t, "workload-project-prod", config["workload_project_id"])
			})
		}
	})
	t.Run("APIProject", func(t *testing.T) {
		t.Parallel()
		for _, tc := range []struct {
			name, project, public, shared string
			args                          []string
			valid                         bool
		}{
			{name: "APIOnly", project: "agora-api-test", shared: "true", valid: true},
			{name: "BothShells", project: "agora-api-test", public: "agora-public-test", shared: "true", valid: true},
			{name: "Explicit", args: []string{"--shared-vpc-enabled", "--public-api-project-id=agora-api-test"}, valid: true},
			{name: "PlatformCollision", project: "agora-public-test", public: "agora-public-test", shared: "true"},
			{name: "ManagementCollision", project: "management-project-prod", shared: "true"},
			{name: "PrivateCollision", project: "workload-project-prod", shared: "true"},
			{name: "Invalid", project: "INVALID", shared: "true"},
			{name: "NoHost", project: "agora-api-test"},
		} {
			t.Run(tc.name, func(t *testing.T) {
				t.Parallel()
				f := foundationCase()
				writes := f.configuration()
				f.env["INFRA_PUBLIC_API_PROJECT_ID"], f.env["INFRA_PUBLIC_PROJECT_ID"], f.env["INFRA_SHARED_VPC_ENABLED"] = tc.project, tc.public, tc.shared
				code, out := f.run(t, append([]string{"configure"}, tc.args...)...)
				if !tc.valid {
					require.Equal(t, 64, code, out)
					require.Empty(t, f.calls)
					return
				}
				require.Zero(t, code, out)
				require.Equal(t, writes, f.mutations)
				require.Len(t, f.secrets, 2)
				require.Equal(t, f.secrets[0], f.secrets[1])
				var config map[string]any
				require.NoError(t, json.Unmarshal(f.secrets[0], &config))
				require.Equal(t, "agora-api-test", config["public_api_project_id"])
				require.Equal(t, "workload-project-prod", config["workload_project_id"])
				if tc.public == "" {
					require.NotContains(t, config, "public_project_id")
				} else {
					require.Equal(t, tc.public, config["public_project_id"])
				}
			})
		}
	})
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
		require.JSONEq(t, `{"management_project_id":"management-project-prod","workload_project_id":"workload-project-prod","service_projects":{},"pgbackrest_repository_services":[],"workload_project_name":"Agora production","backup_bucket_name":"fixture-backups","billing_account_id":"ABCDEF-123456-ABCDEF","organization_id":"123","folder_id":null,"region":"europe-west1","database_zone":"europe-west1-d","subnet_cidr":"10.20.0.0/24","adopt_existing_project":false,"database_operator_principals":["group:db@example.com","user:second@example.com"],"authentication_initializer_principals":["user:init@example.com"],"cost_alert_email":"private@example.com","operations_alert_email":"private@example.com"}`, string(f.secrets[0]))
	})
	t.Run("RepositoryServices", func(t *testing.T) {
		t.Parallel()
		for _, tc := range []struct {
			name, env, flag, projects string
			valid                     bool
		}{
			{"Empty", "[]", "", "{}", true},
			{"Environment", `["json-keys"]`, "", `{"json-keys":"json-keys-project-prod"}`, true},
			{"Explicit", "invalid", `["json-keys"]`, `{"json-keys":"json-keys-project-prod"}`, true},
			{"Disable", `["json-keys"]`, "[]", "{}", true},
			{"Missing", "", "", "{}", false},
			{"Malformed", "private-invalid-json", "", "{}", false},
			{"Null", "null", "", "{}", false},
			{"Object", "{}", "", "{}", false},
			{"NonString", "[123]", "", "{}", false},
			{"Duplicate", `["json-keys","json-keys"]`, "", `{"json-keys":"json-keys-project-prod"}`, false},
			{"Peer", `["authentication"]`, "", `{"authentication":"authentication-prod"}`, false},
			{"Unregistered", `["json-keys"]`, "", "{}", false},
		} {
			t.Run(tc.name, func(t *testing.T) {
				t.Parallel()
				f := foundationCase()
				writes := f.configuration()
				f.env["INFRA_SERVICE_PROJECTS"] = tc.projects
				f.env["INFRA_PGBACKREST_REPOSITORY_SERVICES"] = tc.env
				args, expected := []string{"configure"}, tc.env
				if tc.flag != "" {
					args, expected = append(args, "--pgbackrest-repository-services", tc.flag), tc.flag
				}
				code, out := f.run(t, args...)
				require.NotContains(t, out, "private-invalid-json")
				if !tc.valid {
					require.Equal(t, 64, code)
					require.Empty(t, f.calls)
					return
				}
				require.Zero(t, code, out)
				require.Equal(t, writes, f.mutations)
				require.Len(t, f.secrets, 2)
				require.Equal(t, f.secrets[0], f.secrets[1])
				var config map[string]json.RawMessage
				require.NoError(t, json.Unmarshal(f.secrets[0], &config))
				require.JSONEq(t, expected, string(config["pgbackrest_repository_services"]))
			})
		}
	})
	t.Run("ServiceProjects", func(t *testing.T) {
		t.Parallel()
		for _, tc := range []struct {
			name, env, flag string
			valid           bool
		}{
			{"Environment", `{"json-keys":"json-keys-project-prod"}`, "", true},
			{"Explicit", "invalid", `{"authentication":"authentication-prod"}`, true},
			{"Missing", "", "", false},
			{"Malformed", "private-invalid-json", "", false},
			{"Null", "null", "", false},
			{"Array", "[]", "", false},
			{"NonString", `{"json-keys":123}`, "", false},
		} {
			t.Run(tc.name, func(t *testing.T) {
				t.Parallel()
				f := foundationCase()
				f.configuration()
				f.env["INFRA_SERVICE_PROJECTS"] = tc.env
				args := []string{"configure"}
				expected := tc.env
				if tc.flag != "" {
					args = append(args, "--service-projects", tc.flag)
					expected = tc.flag
				}
				code, out := f.run(t, args...)
				require.NotContains(t, out, "private-invalid-json")
				if !tc.valid {
					require.Equal(t, 64, code)
					require.Empty(t, f.calls)
					return
				}
				require.Zero(t, code, out)
				require.Len(t, f.secrets, 2)
				require.Equal(t, f.secrets[0], f.secrets[1])
				var config map[string]json.RawMessage
				require.NoError(t, json.Unmarshal(f.secrets[0], &config))
				require.JSONEq(t, expected, string(config["service_projects"]))
			})
		}
	})
	t.Run("Retirement", func(t *testing.T) {
		t.Parallel()
		for _, tc := range []struct {
			name, selection, environment string
			args                         []string
			valid, enabled               bool
		}{
			{"Prepare", `{"json-keys":"a-novel-json-keys-prod"}`, "true", nil, true, true},
			{"Remove", `{}`, "true", nil, true, true},
			{"Explicit", `{}`, "", []string{"--retire-json-keys-project"}, true, true},
			{"Disabled", `{}`, "true", []string{"--retire-json-keys-project=false"}, true, false},
			{"WrongProject", `{"json-keys":"different-project"}`, "true", nil, false, false},
			{"Peer", `{"authentication":"a-novel-json-keys-prod"}`, "true", nil, false, false},
			{"Multiple", `{"json-keys":"a-novel-json-keys-prod","authentication":"different-project"}`, "true", nil, false, false},
			{"Malformed", `{}`, "yes", nil, false, false},
		} {
			t.Run(tc.name, func(t *testing.T) {
				t.Parallel()
				f := foundationCase()
				f.configuration()
				replace := strings.NewReplacer("management-project-prod", "a-novel-management-prod", "workload-project-prod", "a-novel-production-prod")
				replies := make(map[string][]string, len(f.replies))
				for command, values := range f.replies {
					for _, value := range values {
						replies[replace.Replace(command)] = append(replies[replace.Replace(command)], replace.Replace(value))
					}
				}
				f.replies = replies
				f.env["INFRA_MANAGEMENT_PROJECT_ID"] = "a-novel-management-prod"
				f.env["INFRA_WORKLOAD_PROJECT_ID"] = "a-novel-production-prod"
				f.env["INFRA_SERVICE_PROJECTS"] = tc.selection
				f.env["INFRA_RETIRE_JSON_KEYS_PROJECT"] = tc.environment
				code, out := f.run(t, append([]string{"configure"}, tc.args...)...)
				if !tc.valid {
					require.Equal(t, 64, code, out)
					require.Empty(t, f.calls)
					return
				}
				require.Zero(t, code, out)
				require.Len(t, f.secrets, 2)
				require.Equal(t, f.secrets[0], f.secrets[1])
				var config map[string]json.RawMessage
				require.NoError(t, json.Unmarshal(f.secrets[0], &config))
				if tc.enabled {
					require.JSONEq(t, "true", string(config["retire_json_keys_project"]))
				} else {
					require.NotContains(t, config, "retire_json_keys_project")
				}
			})
		}
	})
	t.Run("RetirementBoundary", func(t *testing.T) {
		t.Parallel()
		for _, tc := range []struct{ name, key, value string }{
			{"Management", "INFRA_MANAGEMENT_PROJECT_ID", "other-management"},
			{"Workload", "INFRA_WORKLOAD_PROJECT_ID", "other-production"},
			{"Repository", "INFRA_PGBACKREST_REPOSITORY_SERVICES", `["json-keys"]`},
		} {
			t.Run(tc.name, func(t *testing.T) {
				t.Parallel()
				f := foundationCase()
				f.env["INFRA_MANAGEMENT_PROJECT_ID"] = "a-novel-management-prod"
				f.env["INFRA_WORKLOAD_PROJECT_ID"] = "a-novel-production-prod"
				f.env["INFRA_RETIRE_JSON_KEYS_PROJECT"] = "true"
				f.env[tc.key] = tc.value
				code, out := f.run(t, "configure")
				require.Equal(t, 64, code, out)
				require.Empty(t, f.calls)
			})
		}
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
