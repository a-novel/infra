package tests_test

import (
	"testing"

	"github.com/stretchr/testify/require"
	"go.yaml.in/yaml/v3"
)

func TestCloudDeployManifest(t *testing.T) {
	t.Parallel()
	for _, service := range []string{"json-keys"} {
		t.Run(service, func(t *testing.T) {
			t.Parallel()
			var manifest, skaffold object
			require.NoError(t, yaml.Unmarshal([]byte(read(t, "../deploy/cloud-deploy/"+service+"/service.yaml")), &manifest))
			require.NoError(t, yaml.Unmarshal([]byte(read(t, "../deploy/cloud-deploy/"+service+"/skaffold.yaml")), &skaffold))
			require.Equal(t, "serving.knative.dev/v1", manifest["apiVersion"])
			require.Equal(t, "Service", manifest["kind"])
			require.Equal(t, []any{"service.yaml"}, nested(skaffold, "manifests")["rawYaml"])
			require.NotContains(t, skaffold, "build")
			require.Equal(t, object{"cloudrun": object{}}, skaffold["deploy"])
			annotations := nested(nested(manifest, "metadata"), "annotations")
			require.Equal(t, "internal", annotations["run.googleapis.com/ingress"])
			require.Equal(t, "false", annotations["run.googleapis.com/invoker-iam-disabled"])
			require.Equal(t, "1", annotations["run.googleapis.com/minScale"])
			require.Equal(t, "3", annotations["run.googleapis.com/maxScale"])
			spec := nested(manifest, "spec")
			require.NotContains(t, spec, "traffic")
			template := nested(spec, "template")
			require.NotContains(t, nested(template, "metadata"), "name")
			require.Equal(t, "all-traffic", nested(nested(template, "metadata"), "annotations")["run.googleapis.com/vpc-access-egress"])
			containers := nested(template, "spec")["containers"].([]any)
			require.Len(t, containers, 1)
			container := containers[0].(object)
			require.Equal(t, "service-json-keys", container["image"])
			require.Equal(t, object{"cpu": "1", "memory": "512Mi"}, nested(nested(container, "resources"), "limits"))
			env := map[string]object{}
			for _, entry := range container["env"].([]any) {
				value := entry.(object)
				env[value["name"].(string)] = value
			}
			require.Equal(t, "5432", env["POSTGRES_PORT"]["value"])
			for _, name := range []string{"APP_MASTER_KEY", "POSTGRES_PASSWORD"} {
				require.NotContains(t, env[name], "value")
				require.Equal(t, "0", nested(nested(env[name], "valueFrom"), "secretKeyRef")["key"], "unset version must fail closed")
			}
		})
	}
}
