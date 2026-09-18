package submission

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	deploy "cloud.google.com/go/deploy/apiv1"
	"cloud.google.com/go/deploy/apiv1/deploypb"
	"google.golang.org/api/option"
	"google.golang.org/api/storage/v1"
)

// Run exposes the dormant pilot's render-only submission and read-only recovery.
// Cloud clients own authentication and operation waiting; no migration or rollout
// is invoked. A zero exit status never represents a completed deployment.
func Run(ctx context.Context, args []string, stdout, stderr io.Writer, options ...option.ClientOption) int {
	if err := run(ctx, args, stdout, options...); err != nil {
		_, _ = fmt.Fprintln(stderr, err)
		_, _ = fmt.Fprintln(stderr, "Stop. Reconcile the same release identity; do not delete intent, change IDs, or rerun migrations. See docs/runbooks/submit-release.md.")
		return 1
	}
	return 0
}

func run(ctx context.Context, args []string, output io.Writer, options ...option.ClientOption) error {
	if len(args) == 0 || (args[0] != "submit-release" && args[0] != "reconcile-release") {
		return errors.New("expected submit-release or reconcile-release")
	}
	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	var scope scope
	flags.StringVar(&scope.ProjectID, "project-id", "", "reviewed service project ID")
	flags.StringVar(&scope.ProjectNumber, "project-number", "", "reviewed service project number")
	flags.StringVar(&scope.Region, "region", "", "reviewed region")
	flags.StringVar(&scope.ReceiptBucket, "receipt-bucket", "", "private management receipt bucket")
	timeout := flags.Duration("timeout", 10*time.Minute, "creation wait deadline, at most 30m")
	if flags.Parse(args[1:]) != nil || flags.NArg() != 1 {
		return errors.New("expected scope flags followed by a request file (submit) or exact release ID (reconcile)")
	}
	if err := scope.validate(); err != nil {
		return err
	}
	if *timeout <= 0 || *timeout > 30*time.Minute {
		return errors.New("timeout must be positive and at most 30m")
	}
	id := flags.Arg(0)
	var request *deploypb.CreateReleaseRequest
	if args[0] == "submit-release" {
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
		id = request.ReleaseId
	}
	if !releasePattern.MatchString(id) {
		return errors.New("expected a single exact release ID")
	}
	if _, err := fmt.Fprintf(output, "Release: %s/releases/%s\nIntent: gs://%s/%s\n", scope.parent(), id, scope.ReceiptBucket, scope.intentName(id)); err != nil {
		return errors.New("cannot record selected release identity")
	}
	ctx, cancel := context.WithTimeout(ctx, *timeout)
	defer cancel()
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
	if request != nil {
		return client.submit(ctx, request, output)
	}
	return client.reconcile(ctx, id, output)
}
