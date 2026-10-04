package tests_test

import (
	"regexp"
	"slices"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"go.yaml.in/yaml/v3"
)

func TestCloudDeployManifest(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		source, service, role, ingress, invokerDisabled, minimum, egress, throttle, port, user string
		secrets, parameters                                                                    []string
	}{
		{
			"json-keys", "json-keys", "grpc", "internal", "false", "1", "all-traffic", "true", "5432", "agora_json_keys",
			[]string{"APP_MASTER_KEY", "POSTGRES_PASSWORD"},
			[]string{"masterKeyVersion"},
		},
		{
			"json-keys-rest", "json-keys", "rest", "all", "true", "0", "private-ranges-only", "true", "5432", "agora_json_keys",
			[]string{"POSTGRES_PASSWORD"},
			nil,
		},
		{
			"authentication-rest", "authentication", "rest", "all", "true", "1", "private-ranges-only", "false", "5433", "agora_authentication",
			[]string{"POSTGRES_PASSWORD", "SMTP_SENDER_PASSWORD"},
			[]string{"jsonKeysHost", "platformAuthURL", "smtpAddress", "smtpUsername", "smtpSenderDomain", "smtpSenderEmail", "smtpSenderName", "smtpPasswordVersion"},
		},
	} {
		t.Run(testCase.source, func(t *testing.T) {
			t.Parallel()
			var manifest, skaffold object
			source := read(t, "../deploy/cloud-deploy/"+testCase.source+"/service.yaml")
			require.NoError(t, yaml.Unmarshal([]byte(source), &manifest))
			require.NoError(t, yaml.Unmarshal([]byte(read(t, "../deploy/cloud-deploy/"+testCase.source+"/skaffold.yaml")), &skaffold))
			require.Equal(t, "serving.knative.dev/v1", manifest["apiVersion"])
			require.Equal(t, "Service", manifest["kind"])
			require.Equal(t, []any{"service.yaml"}, nested(skaffold, "manifests")["rawYaml"])
			require.NotContains(t, skaffold, "build")
			require.Equal(t, object{"cloudrun": object{}}, skaffold["deploy"])
			annotations := nested(nested(manifest, "metadata"), "annotations")
			require.Equal(t, "agora-"+testCase.service+"-"+testCase.role, nested(manifest, "metadata")["name"])
			require.Equal(t, testCase.ingress, annotations["run.googleapis.com/ingress"])
			require.Equal(t, testCase.invokerDisabled, annotations["run.googleapis.com/invoker-iam-disabled"])
			require.Equal(t, testCase.minimum, annotations["run.googleapis.com/minScale"])
			require.Equal(t, "3", annotations["run.googleapis.com/maxScale"])
			spec := nested(manifest, "spec")
			require.NotContains(t, spec, "traffic")
			template := nested(spec, "template")
			require.NotContains(t, nested(template, "metadata"), "name")
			revisionAnnotations := nested(nested(template, "metadata"), "annotations")
			require.Equal(t, testCase.egress, revisionAnnotations["run.googleapis.com/vpc-access-egress"])
			require.Equal(t, testCase.throttle, revisionAnnotations["run.googleapis.com/cpu-throttling"])
			containers := nested(template, "spec")["containers"].([]any)
			require.Len(t, containers, 1)
			container := containers[0].(object)
			require.Equal(t, "service-"+testCase.service, container["image"])
			require.Equal(t, object{"cpu": "1", "memory": "512Mi"}, nested(nested(container, "resources"), "limits"))
			env := map[string]object{}
			for _, entry := range container["env"].([]any) {
				value := entry.(object)
				env[value["name"].(string)] = value
			}
			require.Equal(t, testCase.port, env["POSTGRES_PORT"]["value"])
			require.Equal(t, testCase.user, env["POSTGRES_USER"]["value"])
			require.Equal(t, testCase.user, env["POSTGRES_DATABASE"]["value"])
			require.Equal(t, "true", env["OTEL"]["value"])
			var secrets []string
			for name, value := range env {
				if _, secret := value["valueFrom"]; secret {
					secrets = append(secrets, name)
				}
			}
			require.ElementsMatch(t, testCase.secrets, secrets)
			for _, name := range secrets {
				require.NotContains(t, env[name], "value")
				require.Equal(t, "0", nested(nested(env[name], "valueFrom"), "secretKeyRef")["key"], "unset version must fail closed")
			}
			if testCase.role == "rest" {
				require.NotContains(t, source, "master-key")
				require.NotContains(t, env, "APP_MASTER_KEY")
				require.Equal(t, "/v2/ping", nested(nested(container, "startupProbe"), "httpGet")["path"])
			}
			if testCase.service == "authentication" {
				require.Equal(t, "9s", env["REST_TIMEOUT_SHUTDOWN"]["value"])
				require.Equal(t, "443", env["SERVICE_JSON_KEYS_PORT"]["value"])
				require.Equal(t, "8", env["SMTP_MAX_CONCURRENT"]["value"])
				require.NotContains(t, env, "WAITLIST_SECRET")
			}
			parameters := []string{"projectId", "network", "subnetwork", "runtimeServiceAccount", "databasePrivateIP", "managementProjectNumber", "postgresPasswordVersion"}
			parameters = append(parameters, testCase.parameters...)
			var actual []string
			for _, match := range regexp.MustCompile(`\$\{([A-Za-z]+)\}`).FindAllStringSubmatch(source, -1) {
				actual = append(actual, match[1])
			}
			slices.Sort(actual)
			require.ElementsMatch(t, parameters, slices.Compact(actual))
		})
	}
}

func TestCloudDeployWaitlist(t *testing.T) {
	t.Parallel()
	for _, name := range []string{"authentication-rest"} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			prefix := "../deploy/cloud-deploy/" + name + "/"
			baseSource := read(t, prefix+"service.yaml")
			variantSource := read(t, prefix+"service-waitlist.yaml")
			var base, variant, skaffold object
			require.NoError(t, yaml.Unmarshal([]byte(baseSource), &base))
			require.NoError(t, yaml.Unmarshal([]byte(variantSource), &variant))
			require.NoError(t, yaml.Unmarshal([]byte(read(t, prefix+"skaffold-waitlist.yaml")), &skaffold))
			require.Equal(t, []any{"service-waitlist.yaml"}, nested(skaffold, "manifests")["rawYaml"])
			require.Equal(t, object{"cloudrun": object{}}, skaffold["deploy"])
			require.NotContains(t, skaffold, "build")
			container := nested(variant, "spec", "template", "spec")["containers"].([]any)[0].(object)
			env := container["env"].([]any)
			require.Equal(t, object{"name": "WAITLIST_URL", "value": "unconfigured"}, env[len(env)-2])
			require.Equal(t, object{"name": "WAITLIST_SECRET", "valueFrom": object{"secretKeyRef": object{"name": "waitlist-secret", "key": "0"}}}, env[len(env)-1])
			container["env"] = env[:len(env)-2]
			require.Equal(t, base, variant, "waitlist must preserve all base API settings")
			for _, line := range strings.Split(baseSource, "\n") {
				if !strings.Contains(line, "# from-param:") {
					continue
				}
				if strings.Contains(line, "run.googleapis.com/secrets:") {
					line += ",waitlist-secret:projects/${managementProjectNumber}/secrets/production-authentication-waitlist-secret"
				}
				require.Contains(t, variantSource, line, "native parameter comments must survive in the variant")
			}
			require.Contains(t, variantSource, ",waitlist-secret:projects/${managementProjectNumber}/secrets/production-authentication-waitlist-secret")
			require.Contains(t, variantSource, "# from-param: ${waitlistURL}")
			require.Contains(t, variantSource, "# from-param: ${waitlistSecretVersion}")
		})
	}
}
