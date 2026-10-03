package tests_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestSharedReleaseInspection(t *testing.T) {
	t.Parallel()
	for _, root := range []string{"service-foundation", "service-release"} {
		for _, testCase := range []struct {
			name, object string
			code         int
		}{
			{name: "Empty"},
			{name: "SavedPlan", object: "plans/" + strings.Repeat("a", 40) + "/123-1/plan.tfplan"},
			{name: "SavedMetadata", object: "plans/" + strings.Repeat("a", 40) + "/123-1/plan.metadata.json"},
			{name: "StateRequiresHandoff", object: "default.tfstate", code: 70},
			{name: "ConfigRequiresHandoff", object: "config/00000000000000000123-00001.tfvars.json", code: 70},
			{name: "HeldOperation", object: "operation.json", code: 70},
			{name: "UnknownPlanObject", object: "plans/latest/123-1/plan.tfplan", code: 70},
			{name: "MissingFolder", code: 70},
			{name: "UnknownFolder", code: 70},
			{name: "Unregistered", code: 70},
			{name: "ObjectsDenied", code: 70},
		} {
			t.Run(root+"/"+testCase.name, func(t *testing.T) {
				t.Parallel()
				f := inspectionFixture(t)
				bucket := "agora-management-test-123-tofu-state"
				private := "workloads/production/private/agora-private-test/json-keys/release/"
				public := "workloads/production/public-api/agora-api-test/json-keys/release/"
				auth := "workloads/production/private/agora-private-test/authentication/release/"
				registration := object{
					"management_project_id": "agora-management-test", "workload_project_id": "agora-private-test",
					"public_api_project_id": "agora-api-test", "region": "europe-west1", "shared_vpc_enabled": true,
					"service_release_zones": object{"json-keys": []string{"private", "public-api"}, "authentication": []string{"private"}},
				}
				f.env["FAKE_GCS_MANAGED_FOLDERS"] = strings.Join([]string{private, public, auth}, "\n")
				f.env["FAKE_GATE_FILES"] = root
				if root == "service-foundation" {
					f.env["FAKE_GATE_FILES"] = "service"
				}
				f.env["FAKE_TOFU_ONLY_ROOT"] = filepath.Join(f.dir, "environments", root)
				switch testCase.name {
				case "MissingFolder":
					f.env["FAKE_GCS_MANAGED_FOLDERS"] = private + "\n" + auth
				case "UnknownFolder":
					f.env["FAKE_GCS_MANAGED_FOLDERS"] += "\nworkloads/production/public/agora-public-test/peer/release/"
				case "Unregistered":
					delete(registration, "service_release_zones")
				case "ObjectsDenied":
					f.env["FAKE_GCS_SERVICE_LIST_FAILURE"] = "true"
				}
				storage := filepath.Join(f.env["FAKE_GCS_ROOT"], bucket)
				writeJSON(t, filepath.Join(storage, "foundation/config/00000000000000000001-00001.tfvars.json"), registration)
				if testCase.object != "" {
					writeJSON(t, filepath.Join(storage, public, testCase.object), object{"private": privateValue})
				}
				output := filepath.Join(f.dir, "assessment.json")
				code, out := f.run(t, "infra", "inspect", "assess", "a-novel/infra", "93", f.env["FAKE_GATE_HEAD"], f.env["FAKE_GATE_BASE"], f.dir, bucket, output)
				expectCode(t, testCase.code, code, out)
				if testCase.code == 0 {
					require.FileExists(t, output)
				} else {
					require.NoFileExists(t, output)
				}
				calls, err := os.ReadFile(f.env["FAKE_TOFU_CALLS"])
				if err != nil {
					require.ErrorIs(t, err, os.ErrNotExist)
				}
				require.NotContains(t, string(calls), " plan ")
				require.NotContains(t, string(calls), " apply ")
				cloud := read(t, f.env["FAKE_GCS_CALLS"])
				require.NotContains(t, cloud, "storage objects list gs://"+bucket+"/workloads/**")
				require.NotContains(t, cloud+out, privateValue)
				if testCase.code == 0 {
					for _, prefix := range []string{private, public, auth} {
						require.Contains(t, cloud, "storage objects list gs://"+bucket+"/"+prefix+"**")
					}
				}
			})
		}
	}
}

func TestSharedReleaseCustody(t *testing.T) {
	t.Parallel()
	for _, zone := range []string{"private", "public-api", "public"} {
		t.Run(zone, func(t *testing.T) {
			t.Parallel()
			scope := "workloads/production/" + zone + "/agora-zone-test/json-keys"
			peerZone := "private"
			if zone == "private" {
				peerZone = "public"
			}
			f, args, metadata := planFixture(t, "service-release", scope)
			f.env["FAKE_GCS_CALLS"] = filepath.Join(f.dir, "storage-calls")
			args[4] = filepath.Join(f.dir, "download.tfplan")
			f.custody(t, 0, append([]string{"plan", "fetch"}, args...)...)
			require.Equal(t, privateValue+"\x00\xff", read(t, args[4]))
			for _, peer := range []struct {
				scope string
				code  int
			}{
				{strings.Replace(scope, "/json-keys", "/authentication", 1), 66},
				{strings.Replace(scope, "/"+zone+"/", "/"+peerZone+"/", 1), 66},
				{strings.Replace(scope, "/"+zone+"/", "/peer/", 1), 65},
				{strings.Replace(scope, "/production/", "/staging/", 1), 65},
				{scope + "/../authentication", 65},
			} {
				f.env["TOFU_STATE_SUFFIX"] = peer.scope
				f.custody(t, peer.code, append([]string{"plan", "fetch"}, args...)...)
			}
			f.env["TOFU_STATE_SUFFIX"] = scope
			config := filepath.Join(f.env["FAKE_GCS_ROOT"], args[0], scope, "release/config/00000000000000000123-00001.tfvars.json")
			writeJSON(t, config, readJSON(t, args[5]))
			download := filepath.Join(f.dir, "configuration.json")
			f.custody(t, 0, "config", "fetch", args[0], "service-release", download)
			require.Equal(t, read(t, config), read(t, download))
			f.custody(t, 65, "config", "publish", args[0], "service-release", download, "124", "1")
			for _, root := range []string{"service-foundation", "service-recovery"} {
				args[1] = root
				planCode, configCode := 65, 65
				if root == "service-foundation" && zone != "public" {
					planCode, configCode = 66, 4
				}
				f.custody(t, planCode, append([]string{"plan", "fetch"}, args...)...)
				f.custody(t, configCode, "config", "fetch", args[0], root, download)
			}
			args[1] = "service-release"
			f.env["MANAGEMENT_PROJECT_ID"] = "agora-management-test"
			f.env["FOUNDATION_CONFIG"] = `{"management_project_id":"agora-management-test","workload_project_id":"agora-production-test","region":"europe-west1","service_projects":{"json-keys":"agora-json-keys-test"}}`
			f.env["SERVICE_JOB_BOOTSTRAP_ENABLED"] = "true"
			f.custody(t, 65, "plan", "apply", args[0], args[1], args[2], args[3], args[5])
			require.FileExists(t, metadata, "blocked apply must preserve the reviewed plan")
			require.NotContains(t, read(t, f.env["FAKE_GCS_CALLS"]), "storage rm")
			writeJSON(t, args[5], object{"changed": true})
			f.custody(t, 77, append([]string{"plan", "fetch"}, args...)...)
		})
	}
}

func TestSharedFoundationInspection(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name  string
		code  int
		plans int
	}{
		{name: "AllScopes", plans: 3},
		{name: "HeldGuard", code: 70},
		{name: "OrphanGuard", code: 70},
		{name: "OrphanState", code: 70},
		{name: "MissingConfig", code: 70},
		{name: "PeerConfig", code: 70},
		{name: "WrongZone", code: 70},
		{name: "RuntimeOptIn", code: 70},
		{name: "LockedState", code: 70},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := inspectionFixture(t)
			bucket := "agora-management-test-123-tofu-state"
			storage := filepath.Join(f.env["FAKE_GCS_ROOT"], bucket)
			f.env["FAKE_GATE_FILES"] = "service"
			f.env["FAKE_TOFU_ONLY_ROOT"] = filepath.Join(f.dir, "environments/service-foundation")
			f.env["FAKE_GCS_MANAGED_FOLDERS"] = ""
			var registration object
			require.NoError(t, json.Unmarshal([]byte(sharedRegistration), &registration))
			writeJSON(t, filepath.Join(storage, "foundation/config/00000000000000000001-00001.tfvars.json"), registration)
			for _, selection := range []struct{ zone, project, service string }{
				{"private", "agora-private-test", "json-keys"},
				{"public-api", "agora-api-test", "authentication"},
				{"public-api", "agora-api-test", "json-keys"},
			} {
				scope := "workloads/production/" + selection.zone + "/" + selection.project + "/" + selection.service
				f.env["FAKE_GCS_MANAGED_FOLDERS"] += scope + "/release/\n"
				writeJSON(t, filepath.Join(storage, "foundation", scope, "default.tfstate"), object{})
				config := object{
					"zone": selection.zone, "project_id": selection.project, "service": selection.service,
					"region": "europe-west1", "management_project_id": "agora-management-test", "state_bucket": bucket,
				}
				if testCase.name == "PeerConfig" {
					config["project_id"] = "agora-peer-test"
				}
				if testCase.name == "WrongZone" {
					config["zone"] = "public"
				}
				if testCase.name == "RuntimeOptIn" {
					config["manage_job_access"] = true
				}
				if testCase.name != "MissingConfig" {
					writeJSON(t, filepath.Join(storage, "foundation", scope, "config/00000000000000000001-00001.tfvars.json"), config)
				}
			}
			switch testCase.name {
			case "HeldGuard", "OrphanGuard":
				service := "json-keys"
				if testCase.name == "OrphanGuard" {
					service = "peer"
				}
				writeJSON(t, filepath.Join(storage, "foundation/operations/production", service, "operation.json"), object{})
			case "OrphanState":
				writeJSON(t, filepath.Join(storage, "foundation/workloads/production/private/agora-peer-test/json-keys/default.tfstate"), object{})
			case "LockedState":
				writeJSON(t, filepath.Join(storage, "foundation/workloads/production/private/agora-private-test/json-keys/default.tflock"), object{})
			}
			output := filepath.Join(f.dir, "assessment.json")
			code, out := f.run(t, "infra", "inspect", "assess", "a-novel/infra", "93", f.env["FAKE_GATE_HEAD"], f.env["FAKE_GATE_BASE"], f.dir, bucket, output)
			expectCode(t, testCase.code, code, out)
			calls, err := os.ReadFile(f.env["FAKE_TOFU_CALLS"])
			if err != nil {
				require.ErrorIs(t, err, os.ErrNotExist)
			}
			require.Equal(t, testCase.plans, strings.Count(string(calls), " plan "))
			require.NotContains(t, string(calls), " apply ")
			if code == 0 {
				require.FileExists(t, output)
			} else {
				require.NoFileExists(t, output)
			}
		})
	}
}
