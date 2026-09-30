// Command native-restore runs once on an approved disposable recovery host.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"cloud.google.com/go/compute/metadata"

	"github.com/a-novel/infra/internal/recovery"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	ctx, cancel := context.WithTimeout(ctx, 50*time.Minute)
	err := run(ctx)
	cancel()
	stop()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("Selected recovery step completed; PostgreSQL stopped. No cutover authorized.")
}

func run(ctx context.Context) error {
	verify := len(os.Args) == 2 && os.Args[1] == "verify-sql"
	if (!verify && len(os.Args) != 1) || os.Getenv("GCE_METADATA_HOST") != "" {
		return errors.New("unsupported recovery arguments or metadata override")
	}
	data, err := os.ReadFile("/etc/agora-recovery/request.json")
	if err != nil {
		return errors.New("read approved recovery request")
	}
	var request recovery.Request
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		return errors.New("invalid recovery request")
	}
	if err = request.Validate(); err != nil {
		return err
	}
	if verify {
		interfaces, err := net.Interfaces()
		if err != nil {
			return errors.New("offline network boundary is unavailable")
		}
		for _, device := range interfaces {
			if device.Flags&net.FlagLoopback == 0 {
				return errors.New("SQL verification requires a networkless container")
			}
		}
		return recovery.VerifySQL(ctx, request, "/recovery", recovery.Command)
	}
	client := metadata.NewClient(nil)
	project, err := client.ProjectIDWithContext(ctx)
	if err != nil || project != request.Project {
		return errors.New("VM is outside the approved recovery project")
	}
	identity, err := client.EmailWithContext(ctx, "default")
	if err != nil || identity != request.Identity() {
		return errors.New("VM does not carry the independent recovery identity")
	}
	return recovery.Restore(ctx, request, "/recovery", recovery.Command)
}
