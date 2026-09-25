// Package custody keeps private plans, configuration and operation evidence.
// Cloud diagnostics and stored payloads never reach logs.
package custody

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"google.golang.org/api/option"
)

type failure struct {
	code    int
	message string
}

func (err failure) Error() string { return err.message }

type store struct {
	ctx             context.Context
	execute         func(context.Context, io.Writer, string, ...string) error
	bucket, scratch string
}

var (
	bucketPattern       = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$`)
	rootPattern         = regexp.MustCompile(`^(bootstrap|foundation|release|service-foundation)$`)
	serviceScopePattern = regexp.MustCompile(`^services/[a-z][a-z0-9-]{4,28}[a-z0-9]$`)
	sequencePattern     = regexp.MustCompile(`^[1-9][0-9]{0,19}-[1-9][0-9]{0,4}$`)
	commitPattern       = regexp.MustCompile(`^[a-f0-9]{40}$`)
)

// Run handles private custody and read-only operation inspection. Exit 4 means a successfully
// listed empty inventory, never an authentication or transport failure.
func Run(ctx context.Context, args []string, getenv func(string) string, execute func(context.Context, io.Writer, string, ...string) error, stdout, stderr io.Writer, options ...option.ClientOption) int {
	err := run(ctx, args, getenv, execute, stdout, options)
	if err == nil {
		message := "Private custody operation completed."
		if len(args) > 1 && args[0] == "operation" && args[1] == "inspect" {
			message = "Read-only inspection completed; no operation was changed."
		}
		_, err = fmt.Fprintln(stdout, message)
	}
	if err == nil {
		return 0
	}
	fault := failure{70, "Private custody operation failed."}
	_ = errors.As(err, &fault)
	if fault.message != "" {
		_, _ = fmt.Fprintln(stderr, fault.message) // Best effort on a closed diagnostic stream.
	}
	return fault.code
}

func run(ctx context.Context, args []string, getenv func(string) string, execute func(context.Context, io.Writer, string, ...string) error, output io.Writer, options []option.ClientOption) error {
	if len(args) < 3 {
		return failure{64, "Usage: infra custody <config|receipt|plan|operation> <action> <bucket> ..."}
	}
	if !bucketPattern.MatchString(args[2]) {
		return failure{65, "Invalid private storage bucket."}
	}
	directory, err := os.MkdirTemp("", "infra-custody-")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(directory) }() // Best-effort private scratch cleanup.
	storage := store{ctx, execute, args[2], directory}
	switch args[0] {
	case "operation":
		if args[1] != "inspect" && args[1] != "finish" {
			return failure{64, "Service operations support inspection or finishing a recorded completion."}
		}
		return storage.inspectOperation(args[1], args[3:], getenv, output, options)
	case "config", "receipt":
		if args[0] == "config" && args[1] == "publish" && len(args) > 3 &&
			(args[3] == "service-foundation" || args[3] == "service-release") {
			return failure{65, "Service configuration publication belongs to the guarded apply operation."}
		}
		return storage.document(args[0], args[1], args[3:], getenv("TOFU_STATE_SUFFIX"))
	case "plan":
		if args[1] == "apply" {
			return storage.apply(args[3:], getenv, output, options)
		}
		return storage.plan(args[1], args[3:], getenv("TOFU_STATE_SUFFIX"))
	default:
		return failure{64, "Unknown custody command."}
	}
}

func (storage store) cloud(output io.Writer, args ...string) error {
	return storage.execute(storage.ctx, output, "gcloud", append([]string{"storage"}, args...)...)
}

func (storage store) upload(uri string, data []byte) error {
	file := filepath.Join(storage.scratch, "upload")
	if err := os.WriteFile(file, data, 0o600); err != nil {
		return err
	}
	return storage.cloud(io.Discard, "cp", file, uri, "--if-generation-match=0", "--quiet")
}

func (storage store) download(uri string) ([]byte, error) {
	file := filepath.Join(storage.scratch, "download")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		return nil, err
	}
	if err := storage.cloud(io.Discard, "cp", uri, file, "--quiet"); err != nil {
		return nil, err
	}
	return os.ReadFile(file)
}

func (storage store) latest(prefix, suffix string) (string, error) {
	var listing strings.Builder
	if err := storage.cloud(&listing, "objects", "list", prefix+"/**", "--format=value(name)"); err != nil {
		return "", failure{70, "Private inventory could not be listed."}
	}
	pattern := regexp.MustCompile(`^[0-9]{20}-[0-9]{5}` + regexp.QuoteMeta(suffix) + `$`)
	latest := ""
	for _, name := range strings.Fields(listing.String()) {
		uri := "gs://" + storage.bucket + "/" + name
		if !strings.HasPrefix(uri, prefix+"/") || !pattern.MatchString(strings.TrimPrefix(uri, prefix+"/")) {
			return "", failure{70, "Private inventory contains an unexpected object."}
		}
		latest = max(latest, uri)
	}
	if latest == "" {
		return "", failure{4, ""}
	}
	return latest, nil
}

func sequenceName(sequence, suffix string) (string, error) {
	if !sequencePattern.MatchString(sequence) {
		return "", failure{64, "Expected a bounded positive run-id-attempt."}
	}
	run, attempt, _ := strings.Cut(sequence, "-")
	return fmt.Sprintf("%020s-%05s%s", run, attempt, suffix), nil
}

// writePrivate replaces the destination only after validation, without following
// an existing symlink or exposing partial downloads under the caller's filename.
func writePrivate(destination string, data []byte) error {
	file, err := os.CreateTemp(filepath.Dir(destination), ".custody-*")
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(file.Name()) }() // Rename may already have removed this path.
	_, writeErr := file.Write(data)
	if err = errors.Join(writeErr, file.Close()); err != nil {
		return err
	}
	return os.Rename(file.Name(), destination)
}
