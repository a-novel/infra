package hostcredentials_test

import (
	"crypto/x509"
	"fmt"
	"hash/crc32"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	secretmanager "cloud.google.com/go/secretmanager/apiv1"
	"cloud.google.com/go/secretmanager/apiv1/secretmanagerpb"
	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"
	"google.golang.org/protobuf/encoding/protojson"

	"github.com/a-novel/infra/internal/hostcredentials"
)

func TestConfig(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name   string
		change func(*hostcredentials.Config)
	}{
		{"Endpoint", func(c *hostcredentials.Config) { c.Endpoint = "peer" }},
		{"ProjectAlias", func(c *hostcredentials.Config) { c.ProjectNumber = "example-management" }},
		{"Latest", func(c *hostcredentials.Config) { c.CAVersion = "latest" }},
		{"ZeroVersion", func(c *hostcredentials.Config) { c.IdentityVersion = "0" }},
		{"WildcardName", func(c *hostcredentials.Config) { c.Name = "*.internal" }},
		{"RelativeOutput", func(c *hostcredentials.Config) { c.Output = "credentials" }},
		{"UncleanOutput", func(c *hostcredentials.Config) { c.Output = "/run/../tmp/credentials" }},
	} {
		t.Run("Error/"+tc.name, func(t *testing.T) {
			t.Parallel()
			config := hostcredentials.Config{ProjectNumber: "123456", Endpoint: "database", CAVersion: "3", IdentityVersion: "7", Name: "database", Output: "/run/credentials"}
			tc.change(&config)
			require.Error(t, config.Validate())
		})
	}
}

func TestDeliver(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name        string
		endpoint    string
		certificate func(*x509.Certificate)
		response    func(*secretmanagerpb.AccessSecretVersionResponse)
		prepare     string
		wantError   string
	}{
		{name: "Success/Database", endpoint: "database"},
		{name: "Success/Repository", endpoint: "repository"},
		{name: "Error/ReadDenied", endpoint: "database", prepare: "denied", wantError: "access database credential"},
		{name: "Error/CrossedVersion", endpoint: "database", response: func(r *secretmanagerpb.AccessSecretVersionResponse) {
			r.Name = strings.Replace(r.Name, "/versions/7", "/versions/8", 1)
		}, wantError: "exact-version"},
		{name: "Error/Checksum", endpoint: "database", response: func(r *secretmanagerpb.AccessSecretVersionResponse) { *r.Payload.DataCrc32C++ }, wantError: "checksum"},
		{name: "Error/MissingChecksum", endpoint: "database", response: func(r *secretmanagerpb.AccessSecretVersionResponse) { r.Payload.DataCrc32C = nil }, wantError: "integrity evidence"},
		{name: "Error/Expired", endpoint: "database", certificate: func(c *x509.Certificate) { c.NotAfter = time.Now().Add(-time.Minute) }, wantError: "validity"},
		{name: "Error/ClientName", endpoint: "database", certificate: func(c *x509.Certificate) { c.Subject.CommonName = "peer" }, wantError: "client certificate CN"},
		{name: "Error/ServerName", endpoint: "repository", certificate: func(c *x509.Certificate) { c.DNSNames = []string{"peer.internal"} }, wantError: "identity certificate"},
		{name: "Error/WrongUsage", endpoint: "repository", certificate: func(c *x509.Certificate) { c.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth} }, wantError: "usage"},
		{name: "Error/SigningIdentity", endpoint: "database", certificate: func(c *x509.Certificate) { c.IsCA, c.BasicConstraintsValid = true, true }, wantError: "must not be a CA"},
		{name: "Error/MismatchedKey", endpoint: "database", prepare: "key", wantError: "valid pair"},
		{name: "Error/Untrusted", endpoint: "database", prepare: "trust", wantError: "trust, validity"},
		{name: "Error/PrivateTrust", endpoint: "database", prepare: "private-trust", wantError: "trust bundle"},
		{name: "Error/ExtraKey", endpoint: "database", prepare: "extra-key", wantError: "exactly one"},
		{name: "Error/ExistingOutput", endpoint: "database", prepare: "existing", wantError: "must not exist"},
		{name: "Error/ConcurrentOutput", endpoint: "database", prepare: "race", wantError: "publish credential directory"},
		{name: "Error/SymlinkOutput", endpoint: "database", prepare: "symlink", wantError: "must not exist"},
		{name: "Error/PublicParent", endpoint: "database", prepare: "public", wantError: "0700"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			ca, identity, expectedName := credentials(t, tc.endpoint, tc.certificate)
			config := hostcredentials.Config{ProjectNumber: "123456", Endpoint: tc.endpoint, CAVersion: "3", IdentityVersion: "7", Name: expectedName, Output: filepath.Join(t.TempDir(), "credentials")}
			require.NoError(t, os.Chmod(filepath.Dir(config.Output), 0o700))
			switch tc.prepare {
			case "key":
				_, other, _ := credentials(t, tc.endpoint, nil)
				identity = append(identity[:strings.Index(string(identity), "-----BEGIN PRIVATE KEY")], other[strings.Index(string(other), "-----BEGIN PRIVATE KEY"):]...)
			case "trust":
				ca, _, _ = credentials(t, tc.endpoint, nil)
			case "private-trust":
				ca = append(ca, identity...)
			case "extra-key":
				identity = append(identity, identity[strings.Index(string(identity), "-----BEGIN PRIVATE KEY"):]...)
			case "existing":
				require.NoError(t, os.Mkdir(config.Output, 0o700))
			case "symlink":
				require.NoError(t, os.Symlink("absent", config.Output))
			case "public":
				require.NoError(t, os.Chmod(filepath.Dir(config.Output), 0o755))
			}

			var lock sync.Mutex
			var requests []string
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				lock.Lock()
				defer lock.Unlock()
				resource := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/v1/"), ":access")
				requests = append(requests, resource)
				payload := ca
				isIdentity := strings.HasSuffix(resource, "/versions/7")
				if isIdentity {
					if tc.prepare == "race" {
						if err := os.Mkdir(config.Output, 0o700); err != nil {
							panic(err)
						}
					}
					if tc.prepare == "denied" {
						http.Error(w, "secret diagnostic that must not escape", http.StatusForbidden)
						return
					}
					payload = identity
				}
				checksum := int64(crc32.Checksum(payload, crc32.MakeTable(crc32.Castagnoli)))
				response := &secretmanagerpb.AccessSecretVersionResponse{Name: resource, Payload: &secretmanagerpb.SecretPayload{Data: payload, DataCrc32C: &checksum}}
				if isIdentity && tc.response != nil {
					tc.response(response)
				}
				data, err := protojson.Marshal(response)
				if err != nil {
					panic(err)
				}
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write(data) // An abandoned test request needs no server-side recovery.
			}))
			t.Cleanup(server.Close)
			client, err := secretmanager.NewRESTClient(t.Context(), option.WithEndpoint(server.URL), option.WithHTTPClient(server.Client()))
			require.NoError(t, err)
			t.Cleanup(func() { require.NoError(t, client.Close()) })

			err = hostcredentials.Deliver(t.Context(), client, config)
			if tc.wantError != "" {
				require.ErrorContains(t, err, tc.wantError)
				require.NotContains(t, err.Error(), "secret diagnostic")
			} else {
				require.NoError(t, err)
				for filename, expected := range map[string][]byte{"ca.pem": ca, "identity.pem": identity} {
					path := filepath.Join(config.Output, filename)
					actual, err := os.ReadFile(path)
					require.NoError(t, err)
					info, err := os.Stat(path)
					require.NoError(t, err)
					require.Equal(t, struct {
						Data []byte
						Mode os.FileMode
					}{expected, 0o400}, struct {
						Data []byte
						Mode os.FileMode
					}{actual, info.Mode().Perm()})
				}
			}
			entries, err := os.ReadDir(filepath.Dir(config.Output))
			require.NoError(t, err)
			var remaining []string
			for _, entry := range entries {
				remaining = append(remaining, entry.Name())
			}
			var expectedEntries []string
			if tc.wantError == "" || tc.prepare == "existing" || tc.prepare == "symlink" || tc.prepare == "race" {
				expectedEntries = []string{"credentials"}
			}
			require.Equal(t, expectedEntries, remaining)
			lock.Lock()
			defer lock.Unlock()
			var expectedRequests []string
			if tc.prepare != "existing" && tc.prepare != "symlink" && tc.prepare != "public" {
				expectedRequests = []string{"projects/123456/secrets/production-json-keys-pgbackrest-ca/versions/3", fmt.Sprintf("projects/123456/secrets/production-json-keys-pgbackrest-%s/versions/7", tc.endpoint)}
			}
			require.Equal(t, expectedRequests, requests)
		})
	}
}
