package submission

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"slices"
	"time"

	deploy "cloud.google.com/go/deploy/apiv1"
	"cloud.google.com/go/deploy/apiv1/deploypb"
	"google.golang.org/api/option"
	"google.golang.org/api/storage/v1"
)

// Run exposes the dormant pilot's source publication, native submission and read-only reconciliation.
// Target approval and durable success receipts remain separate obligations.
func Run(ctx context.Context, args []string, stdout, stderr io.Writer, options ...option.ClientOption) int {
	if err := run(ctx, args, stdout, options...); err != nil {
		_, _ = fmt.Fprintln(stderr, err)
		if len(args) > 0 && args[0] == "publish-release-source" {
			_, _ = fmt.Fprintln(stderr, "Stop. Inspect the source object and checkout; retry only publication with the same inputs. Never delete or overwrite conflicting source. No release submitted. See docs/runbooks/submit-release.md.")
		} else {
			_, _ = fmt.Fprintln(stderr, "Stop. Reconcile the same release identity; do not delete intent, change IDs, or rerun migrations. See docs/runbooks/submit-release.md.")
		}
		return 1
	}
	return 0
}

func run(ctx context.Context, args []string, output io.Writer, options ...option.ClientOption) error {
	if len(args) == 0 || !slices.Contains([]string{"publish-release-source", "submit-release", "reconcile-release", "submit-rollout", "reconcile-rollout"}, args[0]) {
		return errors.New("expected a release or rollout submission/reconciliation command")
	}
	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	var scope scope
	flags.StringVar(&scope.ProjectID, "project-id", "", "reviewed service project ID")
	flags.StringVar(&scope.ProjectNumber, "project-number", "", "reviewed service project number")
	flags.StringVar(&scope.Region, "region", "", "reviewed region")
	flags.StringVar(&scope.ReceiptBucket, "receipt-bucket", "", "private management receipt bucket")
	fromFile := args[0] == "submit-release" || args[0] == "publish-release-source"
	var sourceDirectory string
	if fromFile {
		flags.StringVar(&sourceDirectory, "source-dir", ".", "trusted checkout at the exact source commit")
	}
	var requestID string
	if args[0] == "submit-rollout" {
		flags.StringVar(&requestID, "request-id", "", "new nonzero UUID for this rollout request")
	}
	timeout := flags.Duration("timeout", 10*time.Minute, "creation wait deadline, at most 30m")
	if flags.Parse(args[1:]) != nil || flags.NArg() != 1 {
		return errors.New("expected scope flags and one argument: request file for publication/submission, exact release ID otherwise")
	}
	if err := scope.validate(); err != nil {
		return err
	}
	if *timeout <= 0 || *timeout > 30*time.Minute {
		return errors.New("timeout must be positive and at most 30m")
	}
	if args[0] == "submit-rollout" && !validRequestID(requestID) {
		return errors.New("rollout request-id must be a nonzero lowercase UUID")
	}
	ctx, cancel := context.WithTimeout(ctx, *timeout)
	defer cancel()
	id := flags.Arg(0)
	var request *deploypb.CreateReleaseRequest
	var archive []byte
	if fromFile {
		file, err := os.Open(flags.Arg(0))
		if err != nil {
			return errors.New("cannot open private submission request")
		}
		defer func() { _ = file.Close() }()
		data, err := io.ReadAll(io.LimitReader(file, maxRequestBytes+1))
		if err != nil {
			return errors.New("cannot read private submission request")
		}
		request, err = scope.request(data)
		if err != nil {
			return err
		}
		archive, err = sourceArchive(ctx, sourceDirectory, request.Release.Annotations["source-commit"])
		if err != nil {
			return err
		}
		id = request.ReleaseId
	}
	if !releasePattern.MatchString(id) {
		return errors.New("expected a single exact release ID")
	}
	if _, err := fmt.Fprintf(output, "Release: %s/releases/%s\nIntent: gs://%s/%s\n", scope.parent(), id, scope.ReceiptBucket, scope.intentName(id)); err != nil {
		return errors.New("cannot record selected release identity")
	}
	if args[0] == "submit-rollout" || args[0] == "reconcile-rollout" {
		if _, err := fmt.Fprintf(output, "Rollout: %s/releases/%s/rollouts/production\nRollout intent: gs://%s/%s\n", scope.parent(), id, scope.ReceiptBucket, scope.rolloutIntent(id)); err != nil {
			return errors.New("cannot record selected rollout identity")
		}
	}
	deployClient, err := deploy.NewCloudDeployRESTClient(ctx, options...)
	if err != nil {
		return errors.New("cannot initialize Cloud Deploy client")
	}
	defer func() { _ = deployClient.Close() }()
	storageClient, err := storage.NewService(ctx, options...)
	if err != nil {
		return errors.New("cannot initialize private storage client")
	}
	client := cloud{scope: scope, deploy: deployClient, storage: storageClient}
	switch args[0] {
	case "publish-release-source":
		return client.publishSource(ctx, request, archive, output)
	case "submit-rollout":
		return client.submitRollout(ctx, id, requestID, output)
	case "reconcile-rollout":
		return client.reconcileRollout(ctx, id, output)
	case "submit-release":
		if err := client.verifySource(ctx, request, archive); err != nil {
			return err
		}
		return client.submit(ctx, request, output)
	default:
		return client.reconcile(ctx, id, output)
	}
}
