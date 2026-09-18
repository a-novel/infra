package rollout

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"time"

	"google.golang.org/api/idtoken"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/oauth"
	"google.golang.org/protobuf/types/known/emptypb"
)

// Probe is the payload-free request retained in the exact Cloud Run execution.
type Probe struct {
	URL, Audience, Phase, Revision, Image, JobRun string
}

// Validate confines token use to the selected service's serving or candidate URL.
func (probe Probe) Validate() error {
	if !regexp.MustCompile(`^https://agora-json-keys-grpc-[a-z0-9.-]+\.run\.app$`).MatchString(probe.Audience) ||
		len(probe.Audience) > 253 || probe.Revision == "" || probe.Image == "" || probe.JobRun == "" {
		return errors.New("invalid private probe binding")
	}
	expected := probe.Audience
	if probe.Phase == "canary-0" {
		expected = "https://candidate---" + strings.TrimPrefix(probe.Audience, "https://")
	} else if probe.Phase != "stable" {
		return errors.New("invalid probe phase")
	}
	if probe.URL != expected {
		return errors.New("probe endpoint does not match its phase and audience")
	}
	return nil
}

// RunProbe authenticates from the job's invoker-only identity and checks dependency health.
func RunProbe(ctx context.Context, input string) error {
	var probe Probe
	if len(input) > 4096 || json.Unmarshal([]byte(input), &probe) != nil {
		return errors.New("invalid probe request")
	}
	if err := probe.Validate(); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	tokenSource, err := idtoken.NewTokenSource(ctx, probe.Audience)
	if err != nil {
		return errors.New("probe identity unavailable")
	}
	connection, err := grpc.NewClient(strings.TrimPrefix(probe.URL, "https://")+":443",
		grpc.WithTransportCredentials(credentials.NewTLS(&tls.Config{MinVersion: tls.VersionTLS12})),
		grpc.WithPerRPCCredentials(oauth.TokenSource{TokenSource: tokenSource}),
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(4096)), grpc.WithDisableRetry())
	if err != nil {
		return errors.New("probe connection unavailable")
	}
	defer func() { _ = connection.Close() }()
	// Status has an empty request and returns a gRPC error for any unhealthy
	// dependency. The response fields are intentionally outside this contract.
	if err := connection.Invoke(ctx, "/anovel.jsonkeys.v2.StatusService/Status", &emptypb.Empty{}, &emptypb.Empty{}); err != nil {
		return errors.New("private application health check failed")
	}
	return nil
}
