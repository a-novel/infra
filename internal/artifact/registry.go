package artifact

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"time"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	"github.com/google/go-containerregistry/pkg/v1/google"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"github.com/google/go-containerregistry/pkg/v1/remote/transport"

	"github.com/a-novel/infra/internal/release"
)

// Registry separates image evidence and copying from command/input policy.
// Implementations return payload-free errors safe for operator diagnostics.
type Registry interface {
	Verify(context.Context, release.SourceImage) error
	Copy(context.Context, string, string) error
}

// Client delegates OCI manifests, indexes, authentication and transfers to the
// official registry library. Options allow an isolated registry in tests.
type Client struct{ options []remote.Option }

// NewClient uses Google ADC and Docker's existing credential helpers. Supplying
// options replaces the defaults, allowing anonymous local-registry tests.
func NewClient(options ...remote.Option) *Client {
	if len(options) == 0 {
		options = []remote.Option{remote.WithAuthFromKeychain(authn.NewMultiKeychain(google.Keychain, authn.DefaultKeychain))}
	}
	return &Client{options: options}
}

func (client *Client) get(ctx context.Context, reference string) (*remote.Descriptor, error) {
	ref, err := name.ParseReference(reference, name.StrictValidation)
	if err != nil {
		return nil, err
	}
	return remote.Get(ref, append(slices.Clone(client.options), remote.WithContext(ctx))...)
}

// Verify checks the published tag against the reviewed digest and, for a
// database, PostgreSQL's major on the linux/amd64 image used by our hosts.
func (client *Client) Verify(ctx context.Context, image release.SourceImage) error {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	descriptor, err := client.get(ctx, image.Repository+":"+image.Tag)
	if err != nil || descriptor.Digest.String() != image.Digest {
		return errors.New("a release image tag could not be verified against its reviewed digest")
	}
	if image.Slot != "database" {
		return nil
	}
	database, err := descriptor.Image()
	if err == nil {
		config, configErr := database.ConfigFile()
		if configErr == nil && slices.Contains(config.Config.Env, "PG_MAJOR=18") {
			return nil
		}
	}
	return errors.New("a database image does not declare the reviewed PostgreSQL major")
}

// Copy preserves the entire source descriptor, including indexes. Immutable
// destination tags must be enforced by the registry: a read is not a write lock.
// A failed acknowledgement is reconciled by reading the exact destination; this
// layer never resubmits or deletes a copy to repair an uncertain result.
func (client *Client) Copy(ctx context.Context, source, destination string) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	src, sourceErr := name.NewDigest(source, name.StrictValidation)
	dst, destinationErr := name.NewTag(destination, name.StrictValidation)
	if sourceErr != nil || destinationErr != nil {
		return errors.New("invalid image copy reference")
	}
	existing, err := client.get(ctx, destination)
	if err == nil {
		if existing.Digest.String() != src.DigestStr() {
			return errors.New("an immutable destination tag identifies another digest")
		}
		// An already confirmed copy must not depend on the source staying online.
		return nil
	}
	var registryError *transport.Error
	if !errors.As(err, &registryError) || registryError.StatusCode != http.StatusNotFound || registryError.Request == nil {
		return errors.New("cannot establish destination tag absence; no copy attempted")
	}
	request := registryError.Request
	if request.URL.Host != dst.RegistryStr() || request.URL.Path != "/v2/"+dst.RepositoryStr()+"/manifests/"+dst.TagStr() {
		return errors.New("cannot establish destination tag absence; no copy attempted")
	}
	descriptor, err := client.get(ctx, source)
	if err != nil || descriptor.Digest.String() != src.DigestStr() {
		return errors.New("an immutable source image is unavailable")
	}
	pusher, err := remote.NewPusher(client.options...)
	if err != nil {
		return errors.New("cannot prepare image promotion")
	}
	// Push handles both manifests and indexes without wrapping a single image.
	pushErr := pusher.Push(ctx, dst, descriptor)
	confirmed, err := client.get(ctx, destination)
	if err != nil || confirmed.Digest != descriptor.Digest {
		return errors.New("image promotion is unconfirmed; inspect the exact destination before retrying")
	}
	if pushErr != nil && ctx.Err() != nil {
		return errors.New("image promotion was cancelled; inspect the exact destination before retrying")
	}
	return nil
}
