package tests_test

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

// fixtureCommand implements only the calls made by candidate/probe tests.
// An unexpected invocation leaves a marker checked by the parent, even if the
// production script masks its exit code as an expected deployment failure.
func fixtureCommand(name string, args []string) (int, error) {
	switch name {
	case "tofu-gate.sh", "create-reviewed-plan.sh", "apply-reviewed-plan.sh":
		if os.Getenv("RELEASE_PLAN_SERVICES") != `["json_keys"]` {
			return 99, fmt.Errorf("unexpected plan scope")
		}
		phase := "candidate"
		if name == "tofu-gate.sh" {
			phase = "active"
			if strings.Contains(os.Getenv("TOFU_VAR_FILE"), "/rollback.") {
				phase = "rollback"
			}
		}
		if err := record(name + ":" + phase); err != nil {
			return 99, err
		}
		if os.Getenv("FAIL_PHASE") == phase {
			return 65, nil
		}
	case "gcloud":
		if len(args) < 4 || !slices.Contains(args, "--project=fixture-project") || !slices.Contains(args, "--region=europe-west1") {
			return 99, fmt.Errorf("unexpected cloud scope")
		}
		switch strings.Join(args[:3], " ") {
		case "run revisions describe", "run services describe", "run jobs describe":
			response, err := os.ReadFile(filepath.Join(os.Getenv("TMPDIR"), args[1]+".json"))
			if err != nil {
				return 99, err
			}
			_, err = os.Stdout.Write(response)
			return 0, err
		case "run jobs execute":
			if args[3] != "agora-json-keys-smoke" || !slices.Contains(args, "--wait") || strings.Contains(strings.Join(args, " "), "override") {
				return 99, fmt.Errorf("unexpected probe execution")
			}
			if err := record("probe"); err != nil {
				return 99, err
			}
			if os.Getenv("FAILURE") == "unhealthy" {
				return 1, nil
			}
			_, err := fmt.Fprintln(os.Stdout, "agora-json-keys-smoke-abcde")
			return 0, err
		default:
			return 99, fmt.Errorf("unexpected cloud command: %v", args)
		}
	case "wget":
		if !slices.Contains(args, "--header=Metadata-Flavor: Google") || !slices.Contains(args, "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=https://fixture.run.app") {
			return 99, fmt.Errorf("unexpected metadata request")
		}
		_, err := fmt.Fprint(os.Stdout, privateValue+"-token")
		return 0, err
	case "grpcurl":
		if !slices.Contains(args, "anovel.jsonkeys.v2.StatusService/Status") || !slices.Contains(args, "candidate---fixture.run.app:443") || !slices.Contains(args, "-expand-headers") || strings.Contains(strings.Join(args, " "), privateValue) || os.Getenv("IDENTITY_TOKEN") != privateValue+"-token" {
			return 99, fmt.Errorf("unexpected RPC or exposed token")
		}
		if _, err := fmt.Fprintln(os.Stdout, privateValue+"-response"); err != nil {
			return 99, err
		}
		if _, err := fmt.Fprintln(os.Stderr, privateValue+"-error"); err != nil {
			return 99, err
		}
		return strconv.Atoi(os.Getenv("RPC_CODE"))
	default:
		return 99, fmt.Errorf("unexpected fixture command: %s", name)
	}
	return 0, nil
}

func record(line string) error {
	file, err := os.OpenFile(filepath.Join(os.Getenv("TMPDIR"), "calls"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	_, writeErr := fmt.Fprintln(file, line)
	closeErr := file.Close()
	if writeErr != nil {
		return writeErr
	}
	return closeErr
}
