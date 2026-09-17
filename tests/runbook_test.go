package tests_test

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

var shellFences = regexp.MustCompile("(?ms)^```(sh|zsh|bash)\n(.*?)\n```")

func TestRunbookCommands(t *testing.T) {
	t.Parallel()
	guides, err := filepath.Glob("../docs/runbooks/*.md")
	require.NoError(t, err)
	require.NotEmpty(t, guides)
	for _, guide := range append(guides, "../docs/setup-production.md") {
		t.Run(filepath.Base(guide), func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			zsh, err := exec.LookPath("zsh")
			require.NoError(t, err)
			f.link(t, "zsh", zsh)
			content := read(t, guide)
			if filepath.Base(guide) != "setup-production.md" {
				require.NotContains(t, content, "gcloud run jobs deploy agora-authentication-init")
			}
			for _, block := range shellFences.FindAllStringSubmatch(content, -1) {
				language, body := block[1], block[2]
				shell := "zsh"
				if language == "bash" {
					shell = "bash"
				}
				code, output := f.run(t, shell, "-fn", "-c", body)
				expectCode(t, 0, code, output)
				if language == "zsh" && !strings.HasPrefix(body, "export ") {
					require.True(t, strings.HasPrefix(body, "() {\n"), "zsh options need function scope")
					require.Contains(t, body, "setopt local_options err_return pipe_fail")
					require.Contains(t, body, "unsetopt err_exit nounset xtrace")
					require.Contains(t, body, "} || print -u2 'STOP:")
				}
				body = strings.ReplaceAll(body, "\\\n", " ")
				for _, location := range regexp.MustCompile(`\bgcloud\s+`).FindAllStringIndex(body, -1) {
					command := shellCommand(body[location[0]:])
					switch {
					case regexp.MustCompile(`^gcloud (auth|config|version|organizations|billing)\b|^gcloud resource-manager folders\b`).MatchString(command):
					case strings.HasPrefix(command, "gcloud projects "):
						require.Regexp(t, `^gcloud projects \S+ "\$\{?(INFRA_MANAGEMENT_PROJECT_ID|INFRA_WORKLOAD_PROJECT_ID|MANAGEMENT_PROJECT_ID|WORKLOAD_PROJECT_ID|SOURCE_PROJECT_ID|REPLACEMENT_PROJECT_ID)(:\?[^}]*)?\}?"`, command)
					case strings.HasPrefix(command, "gcloud storage "):
						require.Regexp(t, `gs://\$\{|"\$\{?STATE_OBJECT\}?("|#)`, command)
					default:
						require.Regexp(t, `--project=("\$\{?[A-Z_]+(:\?[^}]*)?\}?"|cos-cloud\b)`, command)
					}
				}
			}
			for _, match := range regexp.MustCompile(`(?:\.\./\.\./|\./)ops/([a-z0-9-]+\.sh)`).FindAllStringSubmatch(content, -1) {
				info, err := os.Stat("../ops/" + match[1])
				require.NoError(t, err)
				require.True(t, info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0, "%s must be executable", match[1])
			}
		})
	}
}

// shellCommand bounds a documented command while preserving quoted logging filters.
// Syntax is checked by the real shell; this scan never evaluates the command.
func shellCommand(body string) string {
	var quote byte
	for index := 0; index < len(body); index++ {
		char := body[index]
		switch {
		case char == '\\' && quote != '\'':
			index++
		case quote != 0:
			if char == quote {
				quote = 0
			}
		case char == '\'' || char == '"':
			quote = char
		case strings.ContainsRune("\n;|)", rune(char)):
			return body[:index]
		}
	}
	return body
}

func TestRunbookIAM(t *testing.T) {
	t.Parallel()
	guide := read(t, "../docs/runbooks/disaster-recovery.md")
	queries := regexp.MustCompile(`gcloud storage buckets get-iam-policy[^\n]+ --format=json \|\njq --exit-status --arg member "\$RESTORE_RUNTIME" '\n([^']+)'`).FindAllStringSubmatch(guide, -1)
	require.Len(t, queries, 2)
	for _, query := range queries {
		require.NotContains(t, query[0], "--filter")
	}
	mutations := regexp.MustCompile(`(?m)^gcloud storage buckets (add|remove)-iam-policy-binding (.+)$`).FindAllStringSubmatch(guide, -1)
	require.Len(t, mutations, 2)
	for _, command := range mutations {
		require.Contains(t, command[2], "--condition=None")
		require.Contains(t, command[2], `--member="$RESTORE_RUNTIME"`)
		require.Contains(t, command[2], "--role=roles/storage.objectViewer")
	}
	const member = "serviceAccount:agora-restore@fixture-project.iam.gserviceaccount.com"
	reader := object{"role": "roles/storage.objectViewer", "members": []string{member}}
	unrelated := object{"role": "roles/storage.objectCreator", "members": []string{"serviceAccount:other"}, "condition": object{"title": "BackupsOnly"}}
	for _, testCase := range []struct {
		name     string
		bindings []object
		codes    []int
	}{
		{"Exact", []object{unrelated, reader}, []int{0, 1}},
		{"Removed", []object{unrelated}, []int{1, 0}},
		{"Empty", []object{}, []int{1, 0}},
		{"Conditional", []object{{"role": reader["role"], "members": reader["members"], "condition": unrelated["condition"]}}, []int{1, 1}},
		{"ExtraRole", []object{reader, {"role": "roles/storage.objectAdmin", "members": reader["members"]}}, []int{1, 1}},
		{"WrongPrincipal", []object{{"role": reader["role"], "members": []string{member + "-different"}}}, []int{1, 0}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			for index, query := range queries {
				code, output := f.run(t, "jq", "-en", "--arg", "member", member, "--argjson", "policy", jsonText(t, object{"bindings": testCase.bindings}), "$policy | "+query[1])
				expectCode(t, testCase.codes[index], code, output)
			}
		})
	}
	for _, testCase := range []struct{ file, condition string }{
		{"configure-hosted-smtp", "SMTP_AUDIT_CONDITION"},
		{"repair-foundation-firewall-access", "FIREWALL_REPAIR_CONDITION"},
	} {
		body := read(t, "../docs/runbooks/"+testCase.file+".md")
		require.Contains(t, body, "request.time < timestamp")
		require.Contains(t, body, "date -u -d '+1 hour'")
		for _, operation := range []string{"add", "remove"} {
			require.Regexp(t, `gcloud projects `+operation+`-iam-policy-binding[^\n]+--condition="\$\{?`+testCase.condition, body)
		}
	}
}

func TestInitializerRunbook(t *testing.T) {
	t.Parallel()
	guide := read(t, "../docs/setup-production.md")
	execute := regexp.MustCompile(`(?m)^gcloud run jobs execute agora-authentication-init (.+)$`).FindAllStringSubmatch(guide, -1)
	require.Len(t, execute, 1)
	require.Regexp(t, `--project="\$\{INFRA_WORKLOAD_PROJECT_ID:\?`, execute[0][1])
	require.Regexp(t, `--region="\$\{REGION:\?`, execute[0][1])
	require.True(t, strings.HasSuffix(execute[0][1], "--wait"))
	require.NotRegexp(t, `--(args|command|update-env-vars|set-env-vars|tasks|task-timeout)`, execute[0][1])
	require.Contains(t, read(t, "../ops/await-auth-initialization.sh"), "docs/setup-production.md#run-the-human-only-authentication-initializer")
	filter := regexp.MustCompile(`\| jq '(\{secretAliases:[^\n]+)'`).FindStringSubmatch(guide)
	require.Len(t, filter, 2)
	inputs := []object{
		{"name": "SUPER_ADMIN_PASSWORD", "value": privateValue},
		{"name": "POSTGRES_PASSWORD", "valueFrom": object{"secretKeyRef": object{"name": "alias", "key": "2"}}},
	}
	payload := object{"spec": object{"template": object{
		"metadata": object{"annotations": object{"run.googleapis.com/secrets": "alias:projects/123/secrets/auth-password"}},
		"spec":     object{"template": object{"spec": object{"containers": []object{{"env": inputs}}}}},
	}}}
	code, output := setup(t).run(t, "jq", "-n", "--argjson", "payload", jsonText(t, payload), "$payload | "+filter[1])
	expectCode(t, 0, code, output)
	var report struct {
		Inputs []struct {
			HasValue  bool
			SecretRef object
		}
	}
	require.NoError(t, json.Unmarshal([]byte(output), &report))
	require.Len(t, report.Inputs, 2)
	require.True(t, report.Inputs[0].HasValue)
	require.Equal(t, object{"name": "alias", "key": "2"}, report.Inputs[1].SecretRef)
}

func TestFirewallOrdering(t *testing.T) {
	t.Parallel()
	blocks := regexp.MustCompile(`(?m)^resource `).Split(read(t, "../environments/production/foundation/network.tf"), -1)
	count := 0
	for _, block := range blocks {
		if strings.HasPrefix(block, `"google_compute_firewall"`) {
			count++
			require.Regexp(t, `depends_on\s*=\s*\[google_project_iam_member\.foundation_firewall\]`, block)
		}
	}
	require.Positive(t, count)
	guide := read(t, "../docs/runbooks/repair-foundation-firewall-access.md")
	permissions := regexp.MustCompile(`--permissions=([^\s]+)`).FindStringSubmatch(guide)
	require.Len(t, permissions, 2)
	require.ElementsMatch(t, []string{"compute.firewalls.create", "compute.firewalls.delete", "compute.firewalls.update"}, strings.Split(permissions[1], ","))
	require.Contains(t, guide, `gcloud iam roles delete "${FIREWALL_REPAIR_ROLE_ID:?}"`)
}

func TestOperatorDefaults(t *testing.T) {
	t.Parallel()
	for index, line := range strings.Split(read(t, "../.envrc"), "\n") {
		if strings.TrimSpace(line) == "" || strings.HasPrefix(line, "#") {
			continue
		}
		require.Regexp(t, `^export [A-Z_]+='[^'\n]*'$`, line, "line %d", index+1)
		require.NotRegexp(t, `(SECRET|TOKEN|PASSWORD|CREDENTIAL|replace-with|\$\(|`+"`"+`)`, line)
	}
}

func runbookBlock(t *testing.T, guide, marker string) string {
	t.Helper()
	for _, block := range shellFences.FindAllStringSubmatch(read(t, "../docs/"+guide+".md"), -1) {
		if strings.Contains(block[2], marker) {
			return block[2]
		}
	}
	t.Fatalf("missing %s command in %s", marker, guide)
	return ""
}
