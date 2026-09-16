package operator_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestRun(t *testing.T) {
	t.Parallel()
	t.Run("Environment", func(t *testing.T) {
		t.Parallel()
		for _, tc := range []struct {
			name               string
			env                map[string]string
			variables, failure string
			code               int
		}{
			{name: "Success/Published", code: 0},
			{name: "Success/Unpublished", variables: `[]`},
			{name: "Success/EmptyPublished", variables: `[{"name":"GCP_MANAGEMENT_PROJECT_ID","value":""}]`},
			{name: "Error/MissingManagement", env: map[string]string{"INFRA_MANAGEMENT_PROJECT_ID": ""}, code: 64},
			{name: "Error/MissingWorkload", env: map[string]string{"INFRA_WORKLOAD_PROJECT_ID": ""}, code: 64},
			{name: "Error/Invalid", env: map[string]string{"INFRA_MANAGEMENT_PROJECT_ID": "INVALID"}, code: 64},
			{name: "Error/Placeholder", env: map[string]string{"INFRA_MANAGEMENT_PROJECT_ID": "replace-with-management-project-id"}, code: 64},
			{name: "Error/SameProject", env: map[string]string{"INFRA_MANAGEMENT_PROJECT_ID": "workload-project-prod"}, code: 64},
			{name: "Error/Mismatch", variables: `[{"name":"GCP_WORKLOAD_PROJECT_ID","value":"other-project"}]`, code: 65},
			{name: "Error/Duplicate", variables: `[{"name":"GCP_WORKLOAD_PROJECT_ID","value":""},{"name":"GCP_WORKLOAD_PROJECT_ID","value":""}]`, code: 65},
			{name: "Error/NullValue", variables: `[{"name":"GCP_WORKLOAD_PROJECT_ID","value":null}]`, code: 65},
			{name: "Error/Object", variables: `{}`, code: 65},
			{name: "Error/Null", variables: `null`, code: 65},
			{name: "Error/Malformed", variables: `{`, code: 65},
			{name: "Error/Command", failure: "variables", code: 65},
		} {
			t.Run(tc.name, func(t *testing.T) {
				t.Parallel()
				responses := map[string]string{}
				if tc.variables != "" {
					responses["variables"] = tc.variables
				}
				r := invoke(t, []string{"verify-env", "--github"}, t.TempDir(), tc.env, responses, tc.failure)
				require.Equal(t, tc.code, r.code)
				if tc.code == 0 {
					require.Equal(t, "PASS published project coordinates\n", r.stdout.String())
				} else {
					require.Empty(t, r.stdout.String())
				}
				if tc.code == 64 {
					require.Empty(t, r.calls)
				}
			})
		}
		r := invoke(t, []string{"verify-env"}, t.TempDir(), nil, nil, "")
		require.Zero(t, r.code)
		require.Empty(t, r.calls)
		require.Equal(t, "PASS operator project coordinates\n", r.stdout.String())
	})
	t.Run("InvalidArguments", func(t *testing.T) {
		t.Parallel()
		for _, args := range [][]string{nil, {"verify-env", "--other"}, {"verify-env", "--github", "extra"}, {"database"}, {"database", "other"}, {"database", "ssh", "other"}, {"database", "inspect", "authentication", "--ttl", "2h"}, {"database", "key", "--ttl", "2h"}, {"database", "key", "--key-file"}, {"database", "key", "--key-file", ""}, {"database", "key", "--key-file", "unsafe\npath"}, {"database", "ssh", "authentication", "--ttl", "0h"}, {"database", "ssh", "authentication", "--ttl", "1h;echo bad"}, {"database", "coordinates", "extra"}} {
			t.Run(strings.Join(args, "/"), func(t *testing.T) {
				t.Parallel()
				r := invoke(t, args, t.TempDir(), nil, nil, "")
				require.Equal(t, 64, r.code)
				require.Empty(t, r.calls)
			})
		}
	})
	t.Run("Database", func(t *testing.T) {
		t.Parallel()
		for _, service := range []string{"authentication", "json-keys"} {
			for _, operation := range []string{"inspect", "ssh", "troubleshoot"} {
				t.Run(service+"/"+operation, func(t *testing.T) {
					t.Parallel()
					directory := t.TempDir()
					key := filepath.Join(directory, "key with spaces;literal")
					args := []string{"database", operation, service}
					if operation != "inspect" {
						args = append(args, "--key-file", key, "--ttl", "2h")
					}
					r := invoke(t, args, directory, nil, nil, "")
					require.Zero(t, r.code, r.stderr.String())
					if operation == "inspect" {
						require.Contains(t, r.stdout.String(), "PASS database host inspection")
						require.Len(t, r.calls, 15)
						require.Contains(t, strings.Join(r.calls[7], " "), "labels.component="+service)
					} else {
						expected := []string{"gcloud", "compute", "ssh", "agora-database-" + service + "-test", "--zone=europe-west1-d", "--ssh-key-file=" + key, "--ssh-key-expire-after=2h", "--tunnel-through-iap"}
						if operation == "troubleshoot" {
							expected = append(expected, "--troubleshoot")
						}
						require.Equal(t, append(expected, "--project=workload-project-prod"), r.calls[len(r.calls)-1])
						require.Equal(t, []string{"ssh-keygen", "-t", "ed25519", "-a", "64", "-C", "a-novel-database-operator", "-f", key}, r.calls[0])
					}
				})
			}
		}
		r := invoke(t, []string{"database", "coordinates"}, t.TempDir(), nil, nil, "")
		require.Zero(t, r.code)
		require.Len(t, r.calls, 8)
		require.JSONEq(t, `{"zone":"europe-west1-d","hosts":{"authentication":{"private_ip":"10.20.0.2","data_disk_id":"1001"},"json_keys":{"private_ip":"10.20.0.3","data_disk_id":"1002"}}}`, r.stdout.String())
	})
	t.Run("DiscoveryFailures", func(t *testing.T) {
		t.Parallel()
		for stage, values := range map[string][]string{
			"zone:authentication":     {"", "europe-west1-d\neurope-west1-c"},
			"instance:authentication": {"", "agora-database-json-keys-test", "agora-database-authentication-a\nagora-database-authentication-b"},
			"ip:authentication":       {"", "8.8.8.8", "10.999.0.1", "10.1", "10.0.0.1\n10.0.0.2", "fd00::1"},
			"disk:authentication":     {"", "0", "123.4", "1\n2"},
			"zone:json-keys":          {"europe-west1-c"},
		} {
			for _, value := range values {
				t.Run(stage+"/"+value, func(t *testing.T) {
					t.Parallel()
					r := invoke(t, []string{"database", "coordinates"}, t.TempDir(), nil, map[string]string{stage: value}, "")
					require.Equal(t, 70, r.code)
					require.Empty(t, r.stdout.String())
				})
			}
		}
		for _, stage := range []string{"zone:authentication", "instance:authentication", "ip:authentication", "disk:authentication", "zone:json-keys", "instance:json-keys", "ip:json-keys", "disk:json-keys", "inspection", "ssh"} {
			t.Run("Command/"+stage, func(t *testing.T) {
				t.Parallel()
				args := []string{"database", "coordinates"}
				if stage == "inspection" {
					args = []string{"database", "inspect", "authentication"}
				}
				if stage == "ssh" {
					args = []string{"database", "ssh", "authentication"}
				}
				r := invoke(t, args, t.TempDir(), nil, nil, stage)
				require.Equal(t, 70, r.code)
				require.NotContains(t, r.stdout.String(), "PASS database host inspection")
				if args[1] == "coordinates" {
					require.Empty(t, r.stdout.String())
				}
			})
		}
	})
	t.Run("Keys", func(t *testing.T) {
		t.Parallel()
		for _, tc := range []struct {
			name, private, public, failure string
			code                           int
		}{
			{name: "Success/Create"},
			{name: "Success/Reuse", private: "private", public: "ssh-ed25519 fixture\n"},
			{name: "Success/ECDSA", private: "private", public: "ecdsa-sha2-nistp256 fixture\n"},
			{name: "Error/HalfPair", private: "private", code: 64},
			{name: "Error/PublicOnly", public: "ssh-ed25519 fixture\n", code: 64},
			{name: "Error/RSA", private: "private", public: "ssh-rsa fixture\n", code: 64},
			{name: "Error/Generation", failure: "keygen", code: 64},
		} {
			t.Run(tc.name, func(t *testing.T) {
				t.Parallel()
				directory := t.TempDir()
				key := filepath.Join(directory, ".ssh", "a-novel-gcp-ed25519")
				if tc.private != "" || tc.public != "" {
					require.NoError(t, os.MkdirAll(filepath.Dir(key), 0o700))
					if tc.private != "" {
						require.NoError(t, os.WriteFile(key, []byte(tc.private), 0o600))
					}
					if tc.public != "" {
						require.NoError(t, os.WriteFile(key+".pub", []byte(tc.public), 0o600))
					}
				}
				r := invoke(t, []string{"database", "key"}, directory, map[string]string{"INFRA_MANAGEMENT_PROJECT_ID": "", "INFRA_WORKLOAD_PROJECT_ID": ""}, nil, tc.failure)
				require.Equal(t, tc.code, r.code)
				require.NotContains(t, r.stdout.String()+r.stderr.String(), "fixture-never-print")
				if tc.code == 0 {
					require.Equal(t, "PASS local SSH key pair\n", r.stdout.String())
					reused := invoke(t, []string{"database", "key", "--key-file", key}, directory, nil, nil, "")
					require.Zero(t, reused.code)
					require.Empty(t, reused.calls)
				}
			})
		}
	})
}
