// Command host-credentials prepares a service's pinned TLS files using its VM identity.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"cloud.google.com/go/compute/metadata"
	secretmanager "cloud.google.com/go/secretmanager/apiv1"
	"golang.org/x/oauth2/google"
	"google.golang.org/api/option"

	"github.com/a-novel/infra/internal/hostcredentials"
)

func main() {
	var config hostcredentials.Config
	var workload, zone string
	flag.StringVar(&config.Service, "service", "", "json-keys or authentication")
	flag.StringVar(&config.ProjectNumber, "management-project-number", "", "numeric project owning TLS secrets")
	flag.StringVar(&workload, "workload-project", "", "project owning the attached endpoint identity")
	flag.StringVar(&zone, "zone", "", "private for shared-project identities; empty for dedicated projects")
	flag.StringVar(&config.Endpoint, "endpoint", "", "database or repository")
	flag.StringVar(&config.CAVersion, "ca-version", "", "numeric public-trust secret version")
	flag.StringVar(&config.IdentityVersion, "identity-version", "", "numeric endpoint secret version")
	flag.StringVar(&config.Name, "name", "", "authorized client CN or server DNS name")
	flag.StringVar(&config.Output, "output", "", "fresh directory beneath a private ephemeral parent")
	flag.Parse()
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	ctx, deadline := context.WithTimeout(ctx, 2*time.Minute)
	err := run(ctx, config, workload, zone)
	deadline()
	cancel()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(ctx context.Context, config hostcredentials.Config, workload, zone string) error {
	if err := config.Validate(); err != nil {
		return err
	}
	if flag.NArg() != 0 || os.Getenv("GCE_METADATA_HOST") != "" {
		return errors.New("invalid workload scope, extra arguments or metadata override")
	}
	account, err := hostcredentials.ServiceAccount(workload, config.Service, config.Endpoint, zone)
	if err != nil {
		return err
	}
	actual, err := metadata.NewClient(nil).EmailWithContext(ctx, "default")
	if err != nil || actual != account {
		return errors.New("attached VM identity does not match the selected endpoint")
	}
	client, err := secretmanager.NewClient(ctx,
		option.WithEndpoint("secretmanager.googleapis.com:443"),
		option.WithTokenSource(google.ComputeTokenSource("default")),
		option.WithLogger(slog.New(slog.NewTextHandler(io.Discard, nil))),
	)
	if err != nil {
		return errors.New("initialize Secret Manager client")
	}
	err = hostcredentials.Deliver(ctx, client, config)
	return errors.Join(err, client.Close())
}
