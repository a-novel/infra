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

// fakeRestoreTools answers the native calls Restore makes, fails the step named failAt, and
// records each step it runs.
type fakeRestoreTools struct {
	t      *testing.T
	failAt string
	calls  []string
}

func (f *fakeRestoreTools) execute(ctx context.Context, _ io.Writer, binary string, args ...string) ([]byte, error) {
	step := args[len(args)-1]
	if strings.HasSuffix(binary, "/pg_controldata") {
		step = "control"
	}
	f.calls = append(f.calls, step)
	if step == f.failAt {
		return nil, errors.New("foo")
	}
	switch step {
	case "--version":
		return []byte("postgres (PostgreSQL) 18.6"), nil
	case "info":
		return []byte(catalog), nil
	case "restore":
		require.Subset(f.t, args, []string{"--set=20260927-200643F", "--type=immediate", "--target-action=pause", "--archive-mode=off"})
		require.False(f.t, slices.Contains(args, "--delta"))
		if f.failAt == "cancel" {
			return nil, context.Canceled
		}
		return nil, ctx.Err()
	case "control":
		if f.failAt == "identity" {
			return []byte("Database system identifier: 7690306691413745680\n"), nil
		}
		return []byte("Database system identifier: 7690306691413745679\n"), nil
	default:
		f.t.Fatalf("unexpected native call %s %v", binary, args)
		return nil, errors.New("unexpected call")
	}
}

func TestRestore(t *testing.T) {
	t.Parallel()
	testCases := []struct {
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
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			parent := t.TempDir()
			if tc.occupied {
				require.NoError(t, os.Mkdir(filepath.Join(parent, "attempt"), 0o700))
			}
			tools := &fakeRestoreTools{t: t, failAt: tc.failAt}
			err := recovery.Restore(t.Context(), selection(), parent, tools.execute)
			_, outcomeErr := os.Stat(filepath.Join(parent, "attempt", "files-restored.json"))
			require.Equal(t, tc.name == "Success", err == nil && outcomeErr == nil)
			require.Equal(t, tc.wantCalls, tools.calls)
			tools.calls = nil
			require.ErrorContains(t, recovery.Restore(t.Context(), selection(), parent, tools.execute), "already used")
			require.Empty(t, tools.calls)
		})
	}
}
