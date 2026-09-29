package recovery_test

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/recovery"
)

func TestRestore(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, failAt string
		occupied     bool
		wantCalls    []string
	}{
		{"Success", "", false, []string{"--version", "info", "restore", "control"}},
		{"Error/Occupied", "", true, nil},
		{"Error/CatalogUnavailable", "info", false, []string{"--version", "info"}},
		{"Error/MissingDependency", "restore", false, []string{"--version", "info", "restore"}},
		{"Error/Interrupted", "cancel", false, []string{"--version", "info", "restore"}},
		{"Error/UnreadableIdentity", "control", false, []string{"--version", "info", "restore", "control"}},
		{"Error/RestoredIdentity", "identity", false, []string{"--version", "info", "restore", "control"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			parent := t.TempDir()
			if tc.occupied {
				require.NoError(t, os.Mkdir(filepath.Join(parent, "attempt"), 0o700))
			}
			var calls []string
			execute := func(ctx context.Context, _ io.Writer, binary string, args ...string) ([]byte, error) {
				step := args[len(args)-1]
				if strings.HasSuffix(binary, "/pg_controldata") {
					step = "control"
				}
				calls = append(calls, step)
				if step == tc.failAt {
					return nil, errors.New("foo")
				}
				switch step {
				case "--version":
					return []byte("postgres (PostgreSQL) 18.6"), nil
				case "info":
					return []byte(catalog), nil
				case "restore":
					require.Subset(t, args, []string{"--set=20260927-200643F", "--type=immediate", "--target-action=pause", "--archive-mode=off"})
					require.False(t, slices.Contains(args, "--delta"))
					if tc.failAt == "cancel" {
						return nil, context.Canceled
					}
					return nil, ctx.Err()
				case "control":
					if tc.failAt == "identity" {
						return []byte("Database system identifier: 7690306691413745680\n"), nil
					}
					return []byte("Database system identifier: 7690306691413745679\n"), nil
				default:
					t.Fatalf("unexpected native call %s %v", binary, args)
					return nil, errors.New("unexpected call")
				}
			}
			err := recovery.Restore(t.Context(), selection(), parent, execute)
			_, outcomeErr := os.Stat(filepath.Join(parent, "attempt", "files-restored.json"))
			require.Equal(t, tc.name == "Success", err == nil && outcomeErr == nil)
			require.Equal(t, tc.wantCalls, calls)
			calls = nil
			require.ErrorContains(t, recovery.Restore(t.Context(), selection(), parent, execute), "already used")
			require.Empty(t, calls)
		})
	}
}
