package tests_test

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestAuthenticationSmoke(t *testing.T) {
	t.Parallel()
	components := []string{"api:jsonKeys", "client:postgres", "client:smtp"}
	health := func(down string) string {
		value := object{}
		for _, component := range components {
			status := "up"
			if component == down {
				status = "down"
			}
			value[component] = object{"status": status}
		}
		return jsonText(t, value)
	}
	type response struct {
		body, status string
		code         int
	}
	type scenario struct {
		name, prerequisite, down, diagnostic string
		responses                            []response
		code                                 int
	}
	healthy := response{health(""), "200", 0}
	unavailable := response{health(components[0]), "503", 0}
	cases := []scenario{{name: "Success", responses: []response{healthy}}}
	for _, prerequisite := range []string{"not-ready", "lookup-failure", "invalid-url"} {
		cases = append(cases, scenario{name: "Error/" + prerequisite, prerequisite: prerequisite, code: 70})
	}
	for _, status := range []string{"200", "503"} {
		for _, component := range components {
			down := response{health(component), status, 0}
			cases = append(cases, scenario{name: "Error/" + component + "/" + status, down: component, responses: []response{down, down, down}, code: 70})
		}
		for index, body := range []string{
			"", healthy.body + "\n" + healthy.body, privateValue, "null", "[]", "{}",
			strings.TrimSuffix(healthy.body, "}") + `,"detail":"` + privateValue + `"}`,
			strings.Replace(healthy.body, `"up"`, `"`+privateValue+`"`, 1),
			strings.Replace(healthy.body, `"status":"up"`, `"status":"up","error":"`+privateValue+`"`, 1),
		} {
			cases = append(cases, scenario{name: fmt.Sprintf("Error/Schema/%s/%d", status, index), responses: []response{{body, status, 0}}, code: 70, diagnostic: "unexpected health response schema"})
		}
		for failures := 1; failures <= 2; failures++ {
			responses := make([]response, failures)
			for index := range responses {
				responses[index] = response{unavailable.body, status, 0}
			}
			cases = append(cases, scenario{name: fmt.Sprintf("Success/Retry/%s/%d", status, failures), responses: append(responses, healthy)})
		}
	}
	for _, terminal := range []struct {
		name, diagnostic string
		response         response
	}{
		{"Transport", "HTTPS request failed", response{privateValue, "", 28}},
		{"Forbidden", "endpoint returned HTTP 403", response{privateValue, "403", 0}},
		{"UnavailableDespiteHealthyBody", "endpoint returned HTTP 503", response{healthy.body, "503", 0}},
		{"InvalidStatus", "unexpected HTTP status", response{healthy.body, privateValue, 0}},
		{"InvalidBody", "unexpected health response schema", response{privateValue, "200", 0}},
	} {
		for _, retry := range []bool{false, true} {
			responses := []response{terminal.response}
			if retry {
				responses = append([]response{unavailable}, responses...)
			}
			cases = append(cases, scenario{name: fmt.Sprintf("Error/%s/AfterDown=%t", terminal.name, retry), responses: responses, code: 70, diagnostic: terminal.diagnostic})
		}
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := driverFixture(t)
			release := readJSON(t, filepath.Join(f.dir, "release.json"))
			nested(release, "revisions")["authentication"] = "auth-candidate"
			release["candidateTag"] = "candidate"
			writeJSON(t, filepath.Join(f.dir, "release.json"), release)
			operations := object{"health": object{"authentication": "not-run", "jsonKeys": "not-run"}}
			writeJSON(t, filepath.Join(f.dir, "operations.json"), operations)
			for _, name := range []string{"gcloud", "curl", "sleep"} {
				f.command(t, name)
			}
			ready, url := "True", "https://candidate.example.run.app"
			if testCase.prerequisite == "not-ready" {
				ready = "False"
			}
			if testCase.prerequisite == "invalid-url" {
				url = "http://example.test"
			}
			calls := []invocation{{Name: "gcloud", Args: []string{"run", "revisions", "describe", "auth-candidate", "--project=fixture-project", "--region=europe-west1", "--format=json"}, Output: `{"status":{"conditions":[{"type":"Ready","status":"` + ready + `"}]}}`}}
			if ready == "True" {
				service := invocation{Name: "gcloud", Args: []string{"run", "services", "describe", "agora-authentication-rest", "--project=fixture-project", "--region=europe-west1", "--format=json"}, Output: `{"status":{"traffic":[{"tag":"candidate","url":"` + url + `"}]}}`}
				if testCase.prerequisite == "lookup-failure" {
					service.Output, service.Code = "", 1
				}
				calls = append(calls, service)
			}
			for index, response := range testCase.responses {
				if index > 0 {
					calls = append(calls, invocation{Name: "sleep", Args: []string{"5"}})
				}
				calls = append(calls, invocation{Name: "curl", Args: []string{
					"--silent", "--proto", "=https", "--tlsv1.2", "--connect-timeout", "5", "--max-time", "15", "--max-filesize", "4096",
					"--header", "Accept: application/json", "--output", "<health-file>", "--write-out", "%{http_code}", url + "/v2/healthcheck",
				}, Output: response.status, Body: response.body, Code: response.code})
			}
			f.expect(t, calls)
			code, out := f.script(t, "google-release-driver", "authentication-smoke")
			expectCode(t, testCase.code, code, out)
			require.JSONEq(t, "[]", read(t, f.env["INFRA_TEST_SEQUENCE"]))
			require.NotContains(t, out, url)
			require.NotContains(t, out, "fixture-project")
			if testCase.code == 0 {
				nested(operations, "health")["authentication"] = "passed"
			}
			require.Equal(t, operations, readJSON(t, filepath.Join(f.dir, "operations.json")))
			files, err := filepath.Glob(filepath.Join(f.dir, "health.*"))
			require.NoError(t, err)
			require.Empty(t, files)
			if testCase.diagnostic != "" {
				require.Contains(t, out, testCase.diagnostic)
				if len(testCase.responses) == 1 {
					require.NotContains(t, out, "Authentication health:")
				}
			}
			if testCase.down != "" {
				for _, component := range components {
					status := "up"
					if component == testCase.down {
						status = "down"
					}
					require.Contains(t, out, component+"="+status)
				}
			}
		})
	}
}
