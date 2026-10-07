package artifact_test

import (
	"strings"
	"testing"
)

func TestPromote(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, mode, service, receipt string
		failure                      int
	}{
		{"Legacy", "release", "", "", -1},
		{"Retention", "release", "", "123", -1},
		{"JSONKeys", "service", "json-keys", "", -1},
		{"Authentication", "service", "authentication", "", -1},
		{"RejectLaterProvenanceBeforeAnyCopy", "service", "json-keys", "", 6},
		{"StopAfterUnconfirmedCopy", "release", "", "", 2},
		{"StopAfterUnconfirmedRetention", "release", "", "123", 1},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			manifest := read(t, "../../tests/fixtures/manifests/valid.yaml")
			compiled := compiledRelease(t, manifest)
			args := []string{"promote", testCase.mode}
			var calls []call
			switch testCase.mode {
			case "service":
				args = append(args, write(t, manifest), write(t, serviceInputs(manifest, testCase.service)))
				calls = imageCalls(manifest, testCase.service)
			case "release":
				args = append(args, write(t, compiled))
				if testCase.receipt != "" {
					args = append(args, testCase.receipt)
				}
			}
			for _, value := range compiled["images"].([]any) {
				image := value.(object)
				source, target, tag := image["sourceDigest"].(string), image["promoted"].(string), image["promotedTag"].(string)
				switch testCase.mode {
				case "service":
					if image["component"] != "service-"+testCase.service {
						continue
					}
					tag = strings.Replace(tag, "/agora-production-test/", "/fixture-service/", 1)
				}
				calls = append(calls, call{"copy", []string{source, tag}, "", false})
				if testCase.receipt != "" {
					calls = append(calls, call{"copy", []string{target, strings.Split(target, "@")[0] + ":receipt-123"}, "", false})
				}
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

func TestPromoteInvalid(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, mode string
		mutate     func(object)
	}{
		{"Release/Empty", "release", func(c object) { c["images"] = []any{} }},
		{"Release/ForeignTarget", "release", func(c object) { c["images"].([]any)[7].(object)["promoted"] = "private-diagnostic" }},
		{"Release/ForeignSource", "release", func(c object) { c["images"].([]any)[0].(object)["repository"] = "private-diagnostic" }},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			compiled := compiledRelease(t, read(t, "../../tests/fixtures/manifests/valid.yaml"))
			testCase.mutate(compiled)
			checkCalls(t, []string{"promote", testCase.mode, write(t, compiled)}, nil, 65)
		})
	}
}
