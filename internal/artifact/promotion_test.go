package artifact_test

import (
	"strings"
	"testing"
)

func TestPromote(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, service string
		failure       int
	}{
		{"JSONKeys", "json-keys", -1},
		{"Authentication", "authentication", -1},
		{"RejectLaterProvenanceBeforeAnyCopy", "json-keys", 6},
		{"StopAfterUnconfirmedCopy", "json-keys", 9},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			manifest := read(t, "../../tests/fixtures/manifests/valid.yaml")
			args := []string{"promote", "service", write(t, manifest), write(t, serviceInputs(manifest, testCase.service))}
			calls := imageCalls(manifest, testCase.service)
			checks := len(calls)
			for index := 1; index < checks; index += 2 {
				image := calls[index]
				source := strings.Split(image.args[0], ":")[0] + "@" + image.args[1]
				tag := strings.Replace(image.args[0], "ghcr.io/a-novel/", "europe-west1-docker.pkg.dev/fixture-service/agora-production/", 1)
				calls = append(calls, call{"copy", []string{source, tag}, "", false})
			}
			code := 0
			if testCase.failure >= 0 {
				code, calls = 70, calls[:testCase.failure+1]
				calls[testCase.failure].fail = true
			}
			checkCalls(t, args, calls, code)
		})
	}
}
