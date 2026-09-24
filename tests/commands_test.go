package tests_test

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"google.golang.org/api/option"

	"github.com/a-novel/infra/internal/custody"
	"github.com/a-novel/infra/internal/inspection"
	"github.com/a-novel/infra/internal/release"
	infraworkflow "github.com/a-novel/infra/internal/workflow"
)

// fixtureCommand implements only the calls expected by these integration tests.
// An unexpected invocation leaves a marker checked by the parent, even if the
// production script masks its exit code as an expected deployment failure.
func fixtureCommand(name string, args []string) (int, error) {
	if sequence := os.Getenv("INFRA_TEST_SEQUENCE"); sequence != "" {
		return expectedCommand(sequence, name, args)
	}
	if os.Getenv("RESTORE_SCENARIO") != "" {
		return restoreCommand(name, args)
	}
	if os.Getenv("SMTP_SCENARIO") != "" {
		return smtpCommand(name, args)
	}
	switch name {
	case "git":
		if len(args) == 4 && args[0] == "-C" {
			switch strings.Join(args[2:], " ") {
			case "rev-parse HEAD":
				_, err := fmt.Fprintln(os.Stdout, os.Getenv("FAKE_GATE_HEAD"))
				return 0, err
			case "status --porcelain":
				_, err := fmt.Fprint(os.Stdout, os.Getenv("FAKE_GIT_DIRTY"))
				return 0, err
			}
		}
		return 99, fmt.Errorf("unexpected inspection git command")
	case "infra":
		if len(args) > 0 && args[0] == "inspect" {
			return inspection.Run(context.Background(), args[1:], os.Getenv, func(ctx context.Context, env []string, name string, args ...string) ([]byte, error) {
				command := exec.CommandContext(ctx, name, args...)
				command.Env = append(os.Environ(), env...)
				return command.Output()
			}, os.Stdout, os.Stderr), nil
		}
		if slices.Equal(args, []string{"assess-images", "verify"}) {
			if os.Getenv("GITHUB_REPOSITORY") != "a-novel/infra" || os.Getenv("HEAD_SHA") != os.Getenv("FAKE_GATE_HEAD") {
				return 99, fmt.Errorf("unexpected image authorization tuple")
			}
			return strconv.Atoi(os.Getenv("FAKE_IMAGE_AUTH_CODE"))
		}
		if len(args) > 0 && args[0] == "foundation-inputs" {
			return infraworkflow.FoundationInputs(args[1:], os.Getenv, os.Stdout, os.Stderr), nil
		}
		if len(args) > 0 && args[0] == "custody" {
			var options []option.ClientOption
			if endpoint := os.Getenv("TEST_STORAGE_ENDPOINT"); endpoint != "" {
				options = []option.ClientOption{option.WithEndpoint(endpoint), option.WithoutAuthentication()}
			}
			return custody.Run(context.Background(), args[1:], os.Getenv, func(ctx context.Context, output io.Writer, name string, args ...string) error {
				command := exec.CommandContext(ctx, name, args...)
				command.Stdout = output
				return command.Run()
			}, os.Stdout, os.Stderr, options...), nil
		}
		return 99, fmt.Errorf("unexpected infra command")
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

// expectedCommand consumes exact calls in order; receipt construction uses the
// real Go entry point so compensation artifacts remain compiler-validated.
func expectedCommand(path, name string, args []string) (int, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 99, err
	}
	var calls []invocation
	if err = json.Unmarshal(data, &calls); err != nil {
		return 99, err
	}
	if len(calls) == 0 || calls[0].Name != name || !slices.Equal(calls[0].Args, args) {
		return 99, fmt.Errorf("unexpected invocation: %s %v; remaining: %v", name, args, calls)
	}
	remaining, err := json.Marshal(calls[1:])
	if err != nil {
		return 99, err
	}
	if err = os.WriteFile(path, remaining, 0o600); err != nil {
		return 99, err
	}
	if name == "infra" && len(args) > 0 && args[0] == "receipt" {
		return release.Run(args, os.Getenv, os.Stdout, os.Stderr), nil
	}
	_, err = fmt.Fprint(os.Stdout, calls[0].Output)
	return calls[0].Code, err
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
