package tests_test

import (
	"fmt"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestRecoveryPreflight(t *testing.T) {
	t.Parallel()
	f := compiledFixture(t)
	foundation, outputs, recovered := filepath.Join(f.dir, "foundation.json"), filepath.Join(f.dir, "outputs.json"), filepath.Join(f.dir, "recovery")
	config := object{}
	for _, key := range []string{"management_project_id", "workload_project_id", "region", "backup_bucket_name"} {
		config[key] = f.config[key]
	}
	writeJSON(t, foundation, config)
	writeJSON(t, outputs, object{
		"workload_project_id": object{"value": "agora-recovery-test"},
		"network": object{"value": object{
			"network_id": "projects/agora-recovery-test/global/networks/agora-production",
			"subnet_id":  "projects/agora-recovery-test/regions/europe-west1/subnetworks/agora-production-europe-west1",
		}},
		"database_hosts": object{"value": object{
			"authentication": object{"private_ip": "10.20.0.8", "data_disk": object{"id": "2001"}},
			"json_keys":      object{"private_ip": "10.20.0.9", "data_disk": object{"id": "2002"}},
		}},
		"cloud_run_invocation_tags": object{"value": object{
			"key": "tagKeys/300000000001", "values": object{
				"initializer": "tagValues/400000000001", "internal": "tagValues/400000000002", "recovery": "tagValues/400000000003", "release": "tagValues/400000000004", "scheduled": "tagValues/400000000005",
			},
		}},
	})
	require.NoError(t, f.compiler.CompileRecovery([]string{foundation, f.files[2], outputs, "agora-recovery-test", "1750000000-json-backup-0", "1750000001-auth-backup-0", "release", recovered}, f.identity))
	var calls []invocation
	for _, pin := range nested(readJSON(t, filepath.Join(f.dir, "first/release.json")), "cloud")["secretVersions"].([]any) {
		pair := pin.([]any)
		calls = append(calls, invocation{Name: "gcloud", Args: []string{"secrets", "versions", "describe", fmt.Sprint(pair[1]), "--secret=" + pair[0].(string), "--project=agora-management-test", "--format=value(state)"}, Output: "ENABLED\n"})
	}
	require.Len(t, calls, 7)
	var quotas []object
	for _, quota := range []struct{ service, value string }{{"run.googleapis.com", "8000"}, {"run.googleapis.com", "17179869184"}, {"compute.googleapis.com", "4"}} {
		quotas = append(quotas, object{"service": quota.service, "dimensions": object{"region": "europe-west1"}, "quotaConfig": object{"preferredValue": quota.value, "grantedValue": quota.value}})
	}
	calls = append(calls, invocation{Name: "gcloud", Args: []string{"quotas", "preferences", "list", "--project=agora-recovery-test", "--format=json"}, Output: jsonText(t, quotas)})
	f.command(t, "gcloud")
	f.expect(t, calls)
	code, out := f.script(t, "preflight-release", filepath.Join(recovered, "preflight.json"))
	expectCode(t, 0, code, out)
	require.Contains(t, out, "Live secret-version and quota preflight passed")
	require.JSONEq(t, "[]", read(t, f.env["INFRA_TEST_SEQUENCE"]))
}
