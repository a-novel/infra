package artifact_test

import (
	"context"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	"github.com/google/go-containerregistry/pkg/registry"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/empty"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/artifact"
	"github.com/a-novel/infra/internal/release"
)

func TestRegistryCopy(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, existing, fault string
		index, cancelled      bool
		wantError             string
		wantWrites            int64
	}{
		{name: "SingleImage", wantWrites: 1},
		{name: "Index", index: true, wantWrites: 3},
		{name: "ExistingExact", existing: "same"},
		{name: "ExistingExactSourceOffline", existing: "same", fault: "source-down"},
		{name: "Conflict", existing: "different", wantError: "another digest"},
		{name: "Denied", fault: "denied", wantError: "no copy attempted"},
		{name: "Unavailable", fault: "unavailable", wantError: "no copy attempted"},
		{name: "RejectedCopy", fault: "reject", wantError: "unconfirmed", wantWrites: 1},
		{name: "LostAcknowledgement", fault: "lost", wantWrites: 1},
		{name: "UnconfirmedAcknowledgement", fault: "unconfirmed", wantError: "unconfirmed", wantWrites: 1},
		{name: "Cancelled", cancelled: true, wantError: "no copy attempted"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			var writes atomic.Int64
			var active atomic.Bool
			server, options := registryServer(t, func(w http.ResponseWriter, r *http.Request, next http.Handler) {
				if active.Load() && testCase.fault == "source-down" && strings.HasPrefix(r.URL.Path, "/v2/source/") {
					http.Error(w, "private-diagnostic", http.StatusServiceUnavailable)
					return
				}
				if strings.HasPrefix(r.URL.Path, "/v2/target/") {
					if r.Method == http.MethodGet && strings.Contains(r.URL.Path, "/manifests/") {
						switch testCase.fault {
						case "denied":
							http.Error(w, "private-diagnostic", http.StatusForbidden)
							return
						case "unavailable":
							http.Error(w, "private-diagnostic", http.StatusServiceUnavailable)
							return
						case "unconfirmed":
							if writes.Load() > 0 {
								http.Error(w, "private-diagnostic", http.StatusForbidden)
								return
							}
						}
					}
					if r.Method == http.MethodPut && strings.Contains(r.URL.Path, "/manifests/") {
						writes.Add(1)
						switch testCase.fault {
						case "reject":
							http.Error(w, "private-diagnostic", http.StatusConflict)
							return
						case "lost":
							next.ServeHTTP(httptest.NewRecorder(), r)
							http.Error(w, "private-diagnostic", http.StatusBadGateway)
							return
						}
					}
				}
				next.ServeHTTP(w, r)
			})
			var image remote.Taggable = databaseImage(t, "18")
			if testCase.index {
				image = mutate.AppendManifests(empty.Index,
					mutate.IndexAddendum{Add: databaseImage(t, "18")},
					mutate.IndexAddendum{Add: databaseImage(t, "17")})
			}
			source := seedImage(t, server+"/source:v1", image, options)
			switch testCase.existing {
			case "same":
				seedImage(t, server+"/target:v1", image, options)
			case "different":
				seedImage(t, server+"/target:v1", empty.Image, options)
			}
			writes.Store(0)
			active.Store(true)
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			if testCase.cancelled {
				cancel()
			}
			client := artifact.NewClient(options...)
			err := client.Copy(ctx, source, server+"/target:v1")
			if testCase.wantError != "" {
				require.ErrorContains(t, err, testCase.wantError)
				require.NotContains(t, err.Error(), "private-diagnostic")
			} else {
				require.NoError(t, err)
				// The same path must also confirm receipt retention, not just version tags.
				err = client.Copy(ctx, strings.Replace(source, "/source@", "/target@", 1), server+"/retained:receipt-123")
				require.NoError(t, err)
			}
			require.Equal(t, testCase.wantWrites, writes.Load())
		})
	}
}

func TestRegistryVerify(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, major, slot, tag, digest string
		wantError                      string
	}{
		{"API", "17", "grpc", "v1", "", ""},
		{"Postgres", "18", "database", "v1", "", ""},
		{"WrongMajor", "17", "database", "v1", "", "PostgreSQL major"},
		{"MissingTag", "18", "database", "missing", "", "reviewed digest"},
		{"Mismatch", "18", "grpc", "v1", "sha256:" + strings.Repeat("0", 64), "reviewed digest"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			server, options := registryServer(t, nil)
			source := seedImage(t, server+"/source:v1", databaseImage(t, testCase.major), options)
			_, digest, _ := strings.Cut(source, "@")
			if testCase.digest != "" {
				digest = testCase.digest
			}
			err := artifact.NewClient(options...).Verify(t.Context(), release.SourceImage{Repository: server + "/source", Tag: testCase.tag, Digest: digest, Slot: testCase.slot})
			if testCase.wantError == "" {
				require.NoError(t, err)
			} else {
				require.ErrorContains(t, err, testCase.wantError)
			}
		})
	}
}

func registryServer(t *testing.T, intercept func(http.ResponseWriter, *http.Request, http.Handler)) (string, []remote.Option) {
	t.Helper()
	base := registry.New(registry.Logger(log.New(io.Discard, "", 0)))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if intercept != nil {
			intercept(w, r, base)
		} else {
			base.ServeHTTP(w, r)
		}
	}))
	t.Cleanup(server.Close)
	return strings.TrimPrefix(server.URL, "http://"), []remote.Option{
		remote.WithAuth(authn.Anonymous), remote.WithContext(t.Context()),
		remote.WithRetryBackoff(remote.Backoff{Steps: 1}),
	}
}

func databaseImage(t *testing.T, major string) v1.Image {
	t.Helper()
	image, err := mutate.ConfigFile(empty.Image, &v1.ConfigFile{OS: "linux", Architecture: "amd64", Config: v1.Config{Env: []string{"PG_MAJOR=" + major}}})
	require.NoError(t, err)
	return image
}

func seedImage(t *testing.T, reference string, image remote.Taggable, options []remote.Option) string {
	t.Helper()
	ref, err := name.NewTag(reference, name.StrictValidation)
	require.NoError(t, err)
	pusher, err := remote.NewPusher(options...)
	require.NoError(t, err)
	require.NoError(t, pusher.Push(t.Context(), ref, image))
	descriptor, err := remote.Get(ref, options...)
	require.NoError(t, err)
	return ref.Context().Name() + "@" + descriptor.Digest.String()
}
