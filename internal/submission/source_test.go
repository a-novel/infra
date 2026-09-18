package submission_test

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"

	"github.com/a-novel/infra/internal/submission"
)

func TestSource(t *testing.T) {
	t.Parallel()
	type outcome struct {
		codes            []int
		uploads, created int
	}
	for _, testCase := range []struct {
		name, local, remote string
		attempts            int
		want                outcome
	}{
		{"Success/Published", "", "", 1, outcome{[]int{0}, 1, 1}},
		{"Success/Reused", "", "", 2, outcome{[]int{0, 0}, 2, 1}},
		{"Success/AcknowledgementLost", "", "lost-ack", 1, outcome{[]int{0}, 1, 1}},
		{"Success/WorkingTreeExcluded", "dirty", "", 1, outcome{[]int{0}, 1, 1}},
		{"Success/ReplacementObjectsIgnored", "replace", "", 1, outcome{[]int{0}, 1, 1}},
		{"Error/WrongCommit", "commit", "", 1, outcome{[]int{1}, 0, 0}},
		{"Error/MissingFile", "missing", "", 1, outcome{[]int{1}, 0, 0}},
		{"Error/Symlink", "symlink", "", 1, outcome{[]int{1}, 0, 0}},
		{"Error/Executable", "executable", "", 1, outcome{[]int{1}, 0, 0}},
		{"Error/OversizedFile", "oversized", "", 1, outcome{[]int{1}, 0, 0}},
		{"Error/UploadDenied", "", "upload-denied", 1, outcome{[]int{1}, 1, 0}},
		{"Error/ReadDenied", "", "read-denied", 1, outcome{[]int{1}, 1, 1}},
		{"Error/ConflictingObject", "", "conflict", 1, outcome{[]int{1}, 1, 0}},
		{"Error/OversizedObject", "", "oversized", 1, outcome{[]int{1}, 1, 0}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			directory := sourceCheckout(t)
			file := filepath.Join(directory, "deploy/cloud-deploy/json-keys/service.yaml")
			expected := map[string]string{}
			for _, name := range []string{"skaffold.yaml", "service.yaml"} {
				data, err := os.ReadFile(filepath.Join(filepath.Dir(file), name))
				require.NoError(t, err)
				expected[name] = string(data)
			}
			switch testCase.local {
			case "missing", "symlink":
				require.NoError(t, os.Remove(file))
				if testCase.local == "symlink" {
					require.NoError(t, os.Symlink("skaffold.yaml", file))
				}
				commitSource(t, directory)
			case "executable":
				require.NoError(t, os.Chmod(file, 0o755))
				commitSource(t, directory)
			case "oversized":
				require.NoError(t, os.WriteFile(file, bytes.Repeat([]byte("x"), 17<<10), 0o644))
				commitSource(t, directory)
			case "dirty", "replace":
				original := gitSource(t, directory, "rev-parse", "HEAD:deploy/cloud-deploy/json-keys/service.yaml")
				require.NoError(t, os.WriteFile(file, []byte("private-input"), 0o644))
				require.NoError(t, os.WriteFile(filepath.Join(filepath.Dir(file), "untracked.json"), []byte("private-input"), 0o600))
				if testCase.local == "replace" {
					replacement := gitSource(t, directory, "hash-object", "-w", file)
					gitSource(t, directory, "replace", original, replacement)
				}
			}
			request := fixture(t)
			sourceName := bindSource(t, request, directory)
			if testCase.local == "commit" {
				// Keep a real, readable source commit while moving HEAD elsewhere: a
				// missing-object failure must not mask the checkout-identity check.
				require.NoError(t, os.WriteFile(filepath.Join(directory, "next.txt"), []byte("next commit"), 0o644))
				commitSource(t, directory)
			}
			path := filepath.Join(t.TempDir(), "request.json")
			require.NoError(t, os.WriteFile(path, wire(t, request), 0o600))
			var stored []byte
			switch testCase.remote {
			case "conflict":
				stored = []byte("private-provider-detail")
			case "oversized":
				stored = bytes.Repeat([]byte("x"), 65<<10)
			}
			var mutex sync.Mutex
			got := outcome{}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mutex.Lock()
				defer mutex.Unlock()
				switch {
				case r.Method == http.MethodPost && r.URL.Path == "/upload/storage/v1/b/"+bucket+"/o":
					got.uploads++
					metadata, data := upload(t, r)
					if metadata.Name != sourceName || r.URL.Query().Get("ifGenerationMatch") != "0" {
						t.Error("source upload is not scoped and create-only")
					}
					if stored != nil {
						http.Error(w, "private-provider-detail", http.StatusPreconditionFailed)
						return
					}
					if testCase.remote == "upload-denied" {
						http.Error(w, "private-provider-detail", http.StatusForbidden)
						return
					}
					stored, got.created = data, got.created+1
					if testCase.remote == "lost-ack" {
						http.Error(w, "private-provider-detail", http.StatusServiceUnavailable)
						return
					}
					metadata.Bucket, metadata.Generation = bucket, 1
					_ = json.NewEncoder(w).Encode(metadata)
				case r.Method == http.MethodGet && r.URL.Path == "/b/"+bucket+"/o/"+sourceName:
					if stored == nil || testCase.remote == "read-denied" {
						http.Error(w, "private-provider-detail", http.StatusForbidden)
						return
					}
					_, _ = w.Write(stored)
				default:
					t.Errorf("unexpected cloud operation: %s %s", r.Method, r.URL.Path)
					http.NotFound(w, r)
				}
			}))
			defer server.Close()
			var codes []int
			for range testCase.attempts {
				var output bytes.Buffer
				codes = append(codes, submission.Run(t.Context(), arguments(t, "publish-release-source", path, directory), &output, &output,
					option.WithEndpoint(server.URL), option.WithoutAuthentication()))
				require.NotContains(t, output.String(), "private-")
			}
			mutex.Lock()
			got.codes = codes
			archive := bytes.Clone(stored)
			mutex.Unlock()
			require.Equal(t, testCase.want, got)
			if codes[0] == 0 {
				zipped, err := gzip.NewReader(bytes.NewReader(archive))
				require.NoError(t, err)
				defer func() { _ = zipped.Close() }() // No file descriptor; the reader owns only this byte buffer.
				reader := tar.NewReader(zipped)
				files := map[string]string{}
				for {
					header, err := reader.Next()
					if errors.Is(err, io.EOF) {
						break
					}
					require.NoError(t, err)
					require.Equal(t, byte(tar.TypeReg), header.Typeflag)
					data, err := io.ReadAll(reader)
					require.NoError(t, err)
					files[header.Name] = string(data)
				}
				require.Equal(t, expected, files)
			}
		})
	}
}
