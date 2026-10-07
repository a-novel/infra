package tests_test

import (
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestTofuGate(t *testing.T) {
	t.Parallel()
	for _, action := range []string{"plan", "assess", "apply", "converge", "drift"} {
		for _, root := range []string{"bootstrap", "foundation"} {
			t.Run(action+"/"+root, func(t *testing.T) {
				t.Parallel()
				f := setup(t)
				f.fake(t, "tofu", "fake-tofu.sh")
				f.link(t, "git", "/usr/bin/true")
				file := filepath.Join(f.dir, "plan.json")
				value := plan("future_resource", object{"deletion_protection": true}, object{"deletion_protection": false})
				writeJSON(t, file, value)
				f.env["FAKE_TOFU_PLAN_JSON"], f.env["FAKE_TOFU_PLAN_CODE"] = file, "2"
				f.env["FAKE_TOFU_FAIL_ACTION"], f.env["ALLOW_RESOURCE_DELETION"] = "apply", "true"
				args := []string{action, root, "fixture-state"}
				if action == "plan" || action == "apply" {
					args = append(args, filepath.Join(f.dir, "saved.tfplan"))
					writeJSON(t, args[3], object{})
				}
				code, out := f.script(t, "tofu-gate", args...)
				expectCode(t, 65, code, out)
				require.NotContains(t, out, "fixture-sensitive-diagnostic")
			})
		}
	}
}
