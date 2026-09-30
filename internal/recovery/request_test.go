package recovery_test

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/recovery"
)

const catalog = `[{"name":"json-keys","status":{"code":0},"db":[{"id":1,"repo-key":1,"system-id":7690306691413745679,"version":"18"}],"backup":[{"label":"20260927-200643F","error":false,"database":{"id":1,"repo-key":1}}]}]`

func selection() recovery.Request {
	return recovery.Request{
		Service: "json-keys", SourceProject: "source-project", Project: "a-novel-recovery-proof",
		ManagementProject: "management-project", ManagementNumber: "123456789012",
		SystemID: "7690306691413745679", Major: 18, Set: "20260927-200643F",
	}
}

func TestRequest(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name   string
		change func(*recovery.Request)
		fail   bool
	}{
		{"Success", func(*recovery.Request) {}, false},
		{"Success/ExplicitCutoff", func(r *recovery.Request) { r.RepositoryTime = "2026-09-27T20:35:40Z" }, false},
		{"Success/Data", func(r *recovery.Request) { r.VerifySQL, r.ExpectedDataSHA256 = true, strings.Repeat("a", 64) }, false},
		{"Error/DataWithoutSQL", func(r *recovery.Request) { r.ExpectedDataSHA256 = strings.Repeat("a", 64) }, true},
		{"Error/MalformedData", func(r *recovery.Request) { r.VerifySQL, r.ExpectedDataSHA256 = true, strings.Repeat("A", 64) }, true},
		{"Error/ShortData", func(r *recovery.Request) { r.VerifySQL, r.ExpectedDataSHA256 = true, "a" }, true},
		{"Error/Peer", func(r *recovery.Request) { r.Service = "authentication" }, true},
		{"Error/SourceTarget", func(r *recovery.Request) { r.Project = r.SourceProject }, true},
		{"Error/ManagementTarget", func(r *recovery.Request) { r.Project = r.ManagementProject }, true},
		{"Error/Major", func(r *recovery.Request) { r.Major = 17 }, true},
		{"Error/Latest", func(r *recovery.Request) { r.Set = "latest" }, true},
		{"Error/OptionInjection", func(r *recovery.Request) { r.Set += "\n--delta" }, true},
		{"Error/SystemID", func(r *recovery.Request) { r.SystemID = "7.69e18" }, true},
		{"Error/RelativeCutoff", func(r *recovery.Request) { r.RepositoryTime = "yesterday" }, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			request := selection()
			tc.change(&request)
			require.Equal(t, tc.fail, request.Validate() != nil)
			if !tc.fail {
				args := strings.Join(request.Arguments(), "\n")
				require.Contains(t, args, "--repo1-gcs-bucket=management-project-123456789012-pgbr-json-keys")
				if request.RepositoryTime != "" {
					require.Contains(t, args, "--repo-target-time="+request.RepositoryTime)
				}
			}
		})
	}
}

func TestRequestCatalog(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, old, replacement string
		fail                   bool
	}{
		{"Success", "", "", false},
		{"Error/Peer", "json-keys", "authentication", true},
		{"Error/Unhealthy", `"code":0`, `"code":1`, true},
		{"Error/MissingStatus", `"code":0`, `"code":null`, true},
		{"Error/Database", "7690306691413745679", "7690306691413745680", true},
		{"Error/Major", `"version":"18"`, `"version":"17"`, true},
		{"Error/ExpiredSet", "20260927-200643F", "20260928-200643F", true},
		{"Error/FailedBackup", `"error":false`, `"error":true`, true},
		{"Error/MissingBackupStatus", `"error":false`, `"error":null`, true},
		{"Error/OtherRepository", `"repo-key":1`, `"repo-key":2`, true},
		{"Error/DatabaseEpoch", `"database":{"id":1`, `"database":{"id":2`, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			data := catalog
			if tc.old != "" {
				data = strings.ReplaceAll(data, tc.old, tc.replacement)
			}
			require.Equal(t, tc.fail, selection().CheckCatalog([]byte(data)) != nil)
		})
	}
}
