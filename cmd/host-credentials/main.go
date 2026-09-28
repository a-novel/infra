// Command host-credentials prepares the JSON Keys pilot's pinned TLS files using its VM identity.
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
	"regexp"
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
	var workload string
	flag.StringVar(&config.ProjectNumber, "management-project-number", "", "numeric project owning TLS secrets")
	flag.StringVar(&workload, "workload-project", "", "project owning the attached endpoint identity")
	flag.StringVar(&config.Endpoint, "endpoint", "", "database or repository")
	flag.StringVar(&config.CAVersion, "ca-version", "", "numeric public-trust secret version")
	flag.StringVar(&config.IdentityVersion, "identity-version", "", "numeric endpoint secret version")
	flag.StringVar(&config.Name, "name", "", "authorized client CN or server DNS name")
	flag.StringVar(&config.Output, "output", "", "fresh directory beneath a private ephemeral parent")
	flag.Parse()
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	ctx, deadline := context.WithTimeout(ctx, 2*time.Minute)
	err := run(ctx, config, workload)
	deadline()
	cancel()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(ctx context.Context, config hostcredentials.Config, workload string) error {
	if err := config.Validate(); err != nil {
		return err
	}
	if flag.NArg() != 0 || !regexp.MustCompile(`^[a-z][a-z0-9-]{4,28}[a-z0-9]$`).MatchString(workload) || os.Getenv("GCE_METADATA_HOST") != "" {
		return errors.New("invalid workload scope, extra arguments or metadata override")
	}
	account := "agora-database"
	if config.Endpoint == "repository" {
		account = "agora-backup-repository"
	}
	actual, err := metadata.NewClient(nil).EmailWithContext(ctx, "default")
	if err != nil || actual != account+"@"+workload+".iam.gserviceaccount.com" {
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
