package hostcredentials

import (
	"context"
	"errors"
	"fmt"
	"hash/crc32"
	"os"
	"path/filepath"
	"regexp"
	"syscall"
	"time"

	secretmanager "cloud.google.com/go/secretmanager/apiv1"
	"cloud.google.com/go/secretmanager/apiv1/secretmanagerpb"
	"golang.org/x/sys/unix"
	"google.golang.org/grpc/status"
)

// Config binds one endpoint to reviewed secret versions and its expected certificate identity.
type Config struct {
	// Service selects the service-owned credentials; endpoints never share secret names.
	Service string
	// ProjectNumber uses Secret Manager's canonical numeric project name.
	ProjectNumber string
	// Endpoint selects the database client or repository server secret.
	Endpoint string
	// CAVersion selects the public trust bundle by numeric version.
	CAVersion string
	// IdentityVersion selects the endpoint's combined certificate/key PEM by numeric version.
	IdentityVersion string
	// Name is the authorized client CN or the server DNS name used by database clients.
	Name string
	// Output is a fresh directory beneath an existing, caller-owned 0700 directory.
	Output string
}

var (
	number = regexp.MustCompile(`^[1-9][0-9]{0,19}$`)
	name   = regexp.MustCompile(`^[a-z0-9][a-z0-9.-]{0,252}$`)
)

// Validate rejects invalid scope before credentials or secret access are requested.
func (c Config) Validate() error {
	if c.Service != "json-keys" && c.Service != "authentication" {
		return errors.New("service must be json-keys or authentication")
	}
	if c.Endpoint != "database" && c.Endpoint != "repository" {
		return errors.New("endpoint must be database or repository")
	}
	if !number.MatchString(c.ProjectNumber) || !number.MatchString(c.CAVersion) || !number.MatchString(c.IdentityVersion) {
		return errors.New("project number and secret versions must be positive decimal identifiers")
	}
	if !name.MatchString(c.Name) || !filepath.IsAbs(c.Output) || filepath.Clean(c.Output) != c.Output || c.Output == "/" {
		return errors.New("expected identity and fresh absolute output directory are required")
	}
	return nil
}

// Deliver publishes ca.pem and identity.pem together, without replacing an existing directory.
// It reads only the selected service's two pinned versions and never returns remote error payloads.
func Deliver(ctx context.Context, client *secretmanager.Client, config Config) (err error) {
	if err := config.Validate(); err != nil {
		return err
	}
	parent := filepath.Dir(config.Output)
	info, err := os.Lstat(parent)
	if err != nil {
		return fmt.Errorf("inspect credential parent: %w", err)
	}
	if !info.IsDir() || info.Mode().Perm() != 0o700 || info.Sys().(*syscall.Stat_t).Uid != uint32(os.Geteuid()) {
		return errors.New("credential parent must be a caller-owned 0700 directory")
	}
	if _, err := os.Lstat(config.Output); !errors.Is(err, os.ErrNotExist) {
		return errors.New("credential output must not exist")
	}

	read := func(endpoint, version string) ([]byte, error) {
		resource := fmt.Sprintf("projects/%s/secrets/production-%s-pgbackrest-%s/versions/%s", config.ProjectNumber, config.Service, endpoint, version)
		response, err := client.AccessSecretVersion(ctx, &secretmanagerpb.AccessSecretVersionRequest{Name: resource})
		if err != nil {
			// Upstream diagnostic bodies are not a safe secret-handling log surface.
			return nil, fmt.Errorf("access %s credential: %s", endpoint, status.Code(err))
		}
		payload := response.GetPayload()
		if response.GetName() != resource || payload == nil || payload.DataCrc32C == nil {
			return nil, errors.New("secret response is missing exact-version integrity evidence")
		}
		if len(payload.Data) == 0 || len(payload.Data) > 65536 || int64(crc32.Checksum(payload.Data, crc32.MakeTable(crc32.Castagnoli))) != *payload.DataCrc32C {
			return nil, errors.New("secret payload size or checksum is invalid")
		}
		return payload.Data, nil
	}
	ca, err := read("ca", config.CAVersion)
	if err != nil {
		return err
	}
	identity, err := read(config.Endpoint, config.IdentityVersion)
	if err != nil {
		return err
	}
	if err := validateCertificate(ca, identity, config, time.Now()); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}

	staging, err := os.MkdirTemp(parent, ".host-tls-")
	if err != nil {
		return fmt.Errorf("prepare credential directory: %w", err)
	}
	defer func() {
		// Only this invocation's private staging directory can be removed.
		err = errors.Join(err, os.RemoveAll(staging))
	}()
	for filename, data := range map[string][]byte{"ca.pem": ca, "identity.pem": identity} {
		if err := os.WriteFile(filepath.Join(staging, filename), data, 0o400); err != nil {
			return fmt.Errorf("write %s: %w", filename, err)
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	// Linux's no-replace rename keeps concurrent starts from replacing a consumer's files.
	if err := unix.Renameat2(unix.AT_FDCWD, staging, unix.AT_FDCWD, config.Output, unix.RENAME_NOREPLACE); err != nil {
		return fmt.Errorf("publish credential directory: %w", err)
	}
	return nil
}
