package tests_test

import (
	"encoding/json"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"google.golang.org/api/storage/v1"
)

// applyStorage exercises only the three conditional writes and the exact delete
// through Google's real client. Existing custody fixtures still own plan transport.
func applyStorage(t *testing.T, f *sandbox, failure string) {
	t.Helper()
	objects := f.env["FAKE_GCS_ROOT"]
	bucket := f.env["STATE_BUCKET"]
	if bucket == "" {
		bucket = "agora-management-test-123-tofu-state"
	}
	planMetadata := filepath.Join(filepath.Dir(f.env["FAKE_TOFU_REQUIRE_ABSENT"]), "plan.metadata.json")
	if f.env["ROOT_NAME"] == "service-recovery" {
		planMetadata = filepath.Join(filepath.Dir(f.env["FAKE_TOFU_REQUIRE_ABSENT"]), "metadata.json")
	}
	guardName := "services/agora-json-keys-test/release/operation.json"
	if strings.HasPrefix(f.env["TOFU_STATE_SUFFIX"], "workloads/") {
		guardName = "foundation/operations/production/json-keys/operation.json"
	}
	legacy := f.env["ROOT_NAME"] == "foundation" && f.env["TOFU_STATE_SUFFIX"] == ""
	if legacy {
		guardName = "release/legacy-maintenance/operation.json"
	}
	guardPath := filepath.Join(objects, bucket, guardName)
	if failure == "busy" {
		writeJSON(t, guardPath, object{"root": "service-foundation", "runId": "other-writer"})
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if err := recover(); err != nil {
				t.Errorf("storage fixture failed: %v", err)
			}
		}()
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodGet {
			bucket, name, ok := strings.Cut(strings.TrimPrefix(r.URL.Path, "/b/"), "/o/")
			data, err := os.ReadFile(filepath.Join(objects, bucket, name))
			if !ok || err != nil {
				http.Error(w, privateValue, http.StatusNotFound)
				return
			}
			if r.URL.Query().Get("alt") == "media" {
				if r.URL.Query().Get("generation") != "42" {
					t.Error("state download must be generation pinned")
				}
				_, _ = w.Write(data)
			} else {
				_ = json.NewEncoder(w).Encode(&storage.Object{Bucket: bucket, Name: name, Generation: 42, TimeCreated: time.Now().Add(-time.Hour).Format(time.RFC3339)})
			}
			return
		}
		if r.Method == http.MethodDelete {
			if r.URL.Path != "/b/"+bucket+"/o/"+guardName ||
				r.URL.Query().Get("ifGenerationMatch") != "42" || r.URL.Query().Get("generation") != "" {
				t.Error("delete must match only the acknowledged live guard generation")
			}
			if failure == "successor" {
				http.Error(w, privateValue, http.StatusPreconditionFailed)
				return
			}
			if err := os.Remove(guardPath); err != nil {
				panic(err)
			}
			if failure == "delete-ack" {
				http.Error(w, privateValue, http.StatusServiceUnavailable)
				return
			}
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.Method != http.MethodPost || r.URL.Query().Get("ifGenerationMatch") != "0" || !strings.HasPrefix(r.URL.Path, "/upload/storage/v1/b/") {
			t.Errorf("unexpected operation: %s %s", r.Method, r.URL)
			http.Error(w, privateValue, http.StatusBadRequest)
			return
		}
		_, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if err != nil {
			panic(err)
		}
		reader := multipart.NewReader(r.Body, params["boundary"])
		metadata, err := reader.NextPart()
		if err != nil {
			panic(err)
		}
		object := &storage.Object{}
		if err := json.NewDecoder(metadata).Decode(object); err != nil {
			panic(err)
		}
		media, err := reader.NextPart()
		if err != nil {
			panic(err)
		}
		data, err := io.ReadAll(media)
		if err != nil {
			panic(err)
		}
		bucket := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/upload/storage/v1/b/"), "/o")
		stage := "guard"
		if strings.Contains(object.Name, "/config/") {
			stage = "config"
		}
		if object.Name != guardName && (strings.Contains(object.Name, "/operations/") || strings.Contains(object.Name, "/completions/")) {
			stage = "completion"
		}
		if stage != "guard" {
			if _, err := os.Stat(guardPath); err != nil {
				t.Error("publication must occur while the guard is held")
			}
		}
		if stage == "completion" && !legacy {
			var record struct {
				Configuration struct{ Bucket, Object string }
			}
			if err := json.Unmarshal(data, &record); err != nil {
				panic(err)
			}
			if _, err := os.Stat(filepath.Join(objects, record.Configuration.Bucket, record.Configuration.Object)); err != nil {
				t.Error("completion must follow configuration publication")
			}
		}
		if failure == stage+"-denied" {
			http.Error(w, privateValue, http.StatusPreconditionFailed)
			return
		}
		path := filepath.Join(objects, bucket, object.Name)
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			panic(err)
		}
		file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err != nil {
			if !os.IsExist(err) {
				panic(err)
			}
			http.Error(w, privateValue, http.StatusPreconditionFailed)
			return
		}
		if _, err := file.Write(data); err != nil {
			panic(err)
		}
		if err := file.Close(); err != nil {
			panic(err)
		}
		if stage == "guard" {
			if err := os.WriteFile(filepath.Join(f.dir, "admitted-guard.json"), data, 0o600); err != nil {
				panic(err)
			}
			if failure == "consume" {
				if err := os.Remove(planMetadata); err != nil {
					panic(err)
				}
			}
		}
		if failure == stage+"-ack" {
			http.Error(w, privateValue, http.StatusServiceUnavailable)
			return
		}
		object.Bucket, object.Generation = bucket, 42
		if failure == "invalid-ack" && stage == "guard" {
			object.Generation = 0
		}
		if err := json.NewEncoder(w).Encode(object); err != nil {
			panic(err)
		}
	}))
	t.Cleanup(server.Close)
	f.env["TEST_STORAGE_ENDPOINT"] = server.URL
}
