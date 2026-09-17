package tests_test

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestSMTPRunbook(t *testing.T) {
	t.Parallel()
	const host = "https://fixture-auth.run.app"
	for _, testCase := range []struct {
		name, marker, scenario, key, value, calls string
		success                                   bool
	}{
		{"Send", "register", "success", "", "", "anon\nregister\n", true},
		{"Health", "healthcheck", "success", "", "", "health\n", true},
		{"Denied", "healthcheck", "denied", "", "", "", false},
		{"Unhealthy", "healthcheck", "unhealthy", "", "", "health\n", false},
		{"DependencyDown", "healthcheck", "dependency-down", "", "", "health\n", false},
		{"AuthFailure", "register", "anon-failed", "", "", "anon\n", false},
		{"InvalidJSON", "register", "invalid-json", "", "", "anon\n", false},
		{"MissingToken", "register", "missing-token", "", "", "anon\n", false},
		{"HeaderInjection", "register", "newline-token", "", "", "anon\n", false},
		{"Timeout", "register", "mail-timeout", "", "", "anon\nregister\n", false},
		{"WrongStatus", "register", "wrong-status", "", "", "anon\nregister\n", false},
		{"MissingEmail", "register", "success", "SMTP_TEST_EMAIL", "", "", false},
		{"InvalidEmail", "register", "success", "SMTP_TEST_EMAIL", "invalid", "", false},
		{"InvalidURL", "register", "success", "AUTH_URL", "http://untrusted.example", "", false},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			for _, name := range []string{"zsh", "date"} {
				path, err := exec.LookPath(name)
				require.NoError(t, err)
				f.link(t, name, path)
			}
			for _, name := range []string{"gcloud", "curl"} {
				f.command(t, name)
			}
			f.env["AUTH_URL"], f.env["SMTP_TEST_EMAIL"], f.env["SMTP_SCENARIO"] = host, "controlled@example.net", testCase.scenario
			if testCase.key != "" {
				f.env[testCase.key] = testCase.value
			}
			marker := "/v2/" + testCase.marker
			if testCase.marker == "register" {
				marker = "/v2/short-code/register"
			}
			block := runbookBlock(t, "runbooks/configure-hosted-smtp", marker)
			code, output := f.run(t, "zsh", "-f", "-c", block)
			require.NotContains(t, output, privateValue)
			if testCase.success {
				expectCode(t, 0, code, output)
				require.NotContains(t, output, "STOP")
				if testCase.marker == "register" {
					require.Contains(t, output, "Request accepted")
				} else {
					require.Contains(t, output, "true")
				}
			} else {
				require.Regexp(t, "STOP|Set a controlled", output)
				require.NotContains(t, output, "Request accepted")
				require.NotContains(t, output, "true")
			}
			calls, err := os.ReadFile(filepath.Join(f.dir, "calls"))
			if testCase.calls != "" {
				require.NoError(t, err)
			}
			require.Equal(t, testCase.calls, string(calls))
		})
	}
}

func smtpCommand(name string, args []string) (int, error) {
	scenario := os.Getenv("SMTP_SCENARIO")
	if name == "gcloud" {
		if !slices.Equal(args, []string{"run", "services", "describe", "agora-authentication-rest", "--project=" + os.Getenv("INFRA_WORKLOAD_PROJECT_ID"), "--region=" + os.Getenv("INFRA_REGION"), "--format=value(status.url)"}) {
			return 99, fmt.Errorf("unexpected SMTP service discovery")
		}
		if scenario == "denied" {
			return 1, nil
		}
		_, err := fmt.Fprint(os.Stdout, "https://fixture-auth.run.app")
		return 0, err
	}
	if name != "curl" || len(args) < 2 || args[0] != "-q" || strings.Contains(strings.Join(append(os.Environ(), args...), " "), privateValue) {
		return 99, fmt.Errorf("unexpected SMTP request or exposed credential")
	}
	for _, arg := range args {
		for _, forbidden := range []string{"--retry", "--location", "--insecure", "--verbose", "--trace"} {
			if strings.HasPrefix(arg, forbidden) {
				return 99, fmt.Errorf("unsafe SMTP request option")
			}
		}
	}
	endpoint := strings.TrimPrefix(args[len(args)-1], "https://fixture-auth.run.app/v2/")
	call := map[string]string{"healthcheck": "health", "session/anon": "anon", "short-code/register": "register"}[endpoint]
	if call == "" {
		return 99, fmt.Errorf("unexpected SMTP endpoint")
	}
	if err := record(call); err != nil {
		return 99, err
	}
	response := `{"client:smtp":{"status":"up"},"client:postgres":{"status":"up"},"api:jsonKeys":{"status":"up"}}`
	code := 0
	switch call {
	case "health":
		if scenario == "unhealthy" || scenario == "dependency-down" {
			response = `{"client:smtp":{"status":"down","error":"` + privateValue + `"}}`
			if scenario == "unhealthy" {
				code = 22
			}
		}
	case "anon", "register":
		if !strings.Contains(strings.Join(args, " "), "--request PUT") {
			return 99, fmt.Errorf("unexpected SMTP request method")
		}
		if call == "anon" {
			response = `{"accessToken":"` + privateValue + `-token","refreshToken":"` + privateValue + `-refresh"}`
			switch scenario {
			case "anon-failed":
				return 22, nil
			case "invalid-json":
				response = "not-json"
			case "missing-token":
				response = "{}"
			case "newline-token":
				response = `{"accessToken":"bad\nheader"}`
			}
		} else {
			header, err := io.ReadAll(os.Stdin)
			if err != nil {
				return 99, err
			}
			if string(header) != "Authorization: Bearer "+privateValue+"-token\n" || !slices.Contains(args, `{"email":"controlled@example.net","lang":"en"}`) || !strings.Contains(strings.Join(args, " "), "--header @-") || !strings.Contains(strings.Join(args, " "), "--output /dev/null") {
				return 99, fmt.Errorf("unexpected SMTP payload or token transport")
			}
			if scenario == "mail-timeout" {
				return 28, nil
			}
			response = "202"
			if scenario == "wrong-status" {
				response = "200"
			}
		}
	}
	_, err := fmt.Fprint(os.Stdout, response)
	return code, err
}
