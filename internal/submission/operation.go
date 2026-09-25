package submission

import (
	"context"
	"crypto/sha256"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"google.golang.org/api/option"

	"github.com/a-novel/infra/internal/artifact"
	"github.com/a-novel/infra/internal/rollout"
)

// Operation connects the existing single-dispatch adapters under one service
// reservation. Only the protected native pilot can admit it; errors never unlock.
func Operation(ctx context.Context, args []string, getenv func(string) string, execute func(context.Context, io.Writer, string, ...string) error, registry artifact.Registry, stdout, stderr io.Writer, options ...option.ClientOption) int {
	if err := operate(ctx, args, getenv, execute, registry, stdout, options...); err != nil {
		_, _ = fmt.Fprintln(stderr, err)
		_, _ = fmt.Fprintln(stderr, "Stop. An accepted operation may still be running. Retain any service guard and inspect the recorded release, migration and rollout; never rerun to unlock. See docs/runbooks/submit-release.md.")
		return 1
	}
	return 0
}

func operate(ctx context.Context, args []string, getenv func(string) string, execute func(context.Context, io.Writer, string, ...string) error, registry artifact.Registry, output io.Writer, options ...option.ClientOption) error {
	if len(args) == 2 && args[0] == "prepare" {
		return prepareOperation(args[1], getenv, output)
	}
	if len(args) == 0 || (args[0] != "preflight" && args[0] != "deploy") {
		return errors.New("expected service-release prepare FILE | preflight|deploy [--source-dir DIR] [--timeout DURATION] FILE SHA256")
	}
	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	directory := flags.String("source-dir", ".", "exact reviewed checkout")
	timeout := flags.Duration("timeout", 30*time.Minute, "whole-operation deadline, at most 30m")
	if flags.Parse(args[1:]) != nil || flags.NArg() != 2 || *timeout <= 0 || *timeout > 30*time.Minute {
		return errors.New("invalid service-release arguments")
	}
	ctx, cancel := context.WithTimeout(ctx, *timeout)
	defer cancel()
	file, err := os.Open(flags.Arg(0))
	if err != nil {
		return errors.New("cannot read prepared service operation")
	}
	defer func() { _ = file.Close() }()
	data, err := io.ReadAll(io.LimitReader(file, maxRequestBytes+1))
	if err != nil || fmt.Sprintf("%x", sha256.Sum256(data)) != flags.Arg(1) {
		return errors.New("prepared operation differs from its pre-authentication checksum")
	}
	input, request, err := operationConfig(data, getenv)
	if err != nil {
		return err
	}
	archive, err := sourceArchive(ctx, *directory, request.Release.Annotations["source-commit"])
	if err != nil {
		return err
	}
	manifest := filepath.Join(*directory, "deploy/production/images.yaml")
	if err := artifact.VerifyService(ctx, manifest, data, args[0] == "deploy", execute, registry); err != nil {
		return err
	}
	if args[0] == "preflight" {
		_, err := fmt.Fprintln(output, "PASS selected native release source and complete image family; no cloud mutation.")
		return err
	}
	return withOperation(ctx, input, data, options, func(operation serviceOperation) error {
		return operation.deployRelease(ctx, request, archive, getenv, execute, output, *timeout, options)
	})
}

func (operation *serviceOperation) deployRelease(ctx context.Context, request *deploypb.CreateReleaseRequest, archive []byte, getenv func(string) string, execute func(context.Context, io.Writer, string, ...string) error, output io.Writer, timeout time.Duration, options []option.ClientOption) error {
	if err := operation.acquire(ctx, getenv, output); err != nil {
		return err
	}
	// No deferred release: runner loss, failed prerequisites and uncertain native
	// outcomes all retain admission. There is no time-based takeover.
	if err := operation.jobs(ctx); err != nil {
		return err
	}
	if _, _, err := operation.serving(ctx, operation.input.Predecessor); err != nil {
		return err
	}
	if err := artifact.VerifyServiceSecrets(ctx, operation.data, execute); err != nil {
		return err
	}
	if err := operation.publishSource(ctx, request, archive, output); err != nil {
		return err
	}
	if err := operation.held(ctx); err != nil {
		return err
	}
	if err := operation.submit(ctx, request, output); err != nil {
		return err
	}
	if err := operation.rendered(ctx, request.ReleaseId); err != nil {
		return err
	}
	if err := operation.held(ctx); err != nil {
		return err
	}
	if err := artifact.VerifyServiceSecrets(ctx, operation.data, execute); err != nil {
		return err
	}
	if err := operation.migration(ctx, "submit-migration", request.ReleaseId, operation.approvedMigration.Uid, operation.input.Images["migrations"], output); err != nil {
		return err
	}
	if err := operation.held(ctx); err != nil {
		return err
	}
	if err := operation.createRollout(ctx, request.ReleaseId, operation.input.RolloutRequestID, output, true); err != nil {
		return err
	}
	observer := rollout.Observer{Name: request.Release.Name + "/rollouts/production", Timeout: timeout, AwaitActions: true}
	if err := observer.Wait(ctx, output, options...); err != nil {
		return err
	}
	return operation.finish(ctx, request.ReleaseId, output)
}

func (operation serviceOperation) rendered(ctx context.Context, id string) error {
	for {
		_, release, err := operation.readRelease(ctx, id)
		if err != nil || release.GetAbandoned() {
			return errors.New("render observation unavailable or abandoned")
		}
		switch release.RenderState {
		case deploypb.Release_SUCCEEDED:
			return nil
		case deploypb.Release_IN_PROGRESS:
			select {
			case <-ctx.Done():
				return errors.New("render observation interrupted; service guard retained")
			case <-time.After(10 * time.Second):
			}
		default:
			return errors.New("render failed or unknown; service guard retained")
		}
	}
}
