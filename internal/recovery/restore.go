package recovery

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Executor runs one native tool and returns its standard output, writing its diagnostics to the
// given writer. [Command] is the one the recovery host uses.
type Executor func(ctx context.Context, diagnostics io.Writer, name string, args ...string) ([]byte, error)

// Restore reserves a fresh attempt beneath a private mounted destination. Failed or
// interrupted attempts remain for inspection and cannot be replayed. No server is started.
func Restore(ctx context.Context, request Request, parent string, execute Executor) error {
	if err := request.Validate(); err != nil {
		return err
	}
	root := filepath.Join(parent, "attempt")
	log, err := reserveAttempt(root, request)
	if err != nil {
		return err
	}
	defer func() { _ = log.Close() }() // Evidence remains on the disposable disk even on interruption.
	data := filepath.Join(root, "data")
	args := request.Arguments()
	version, err := runLogged(ctx, execute, log, "/usr/lib/postgresql/18/bin/postgres", "--version")
	if err != nil || !strings.HasPrefix(string(version), "postgres (PostgreSQL) 18.") {
		return errors.New("installed PostgreSQL major differs from the recovery contract")
	}
	catalog, err := runLogged(ctx, execute, log, "/usr/bin/pgbackrest", append(args, "--output=json", "info")...)
	if err != nil {
		return errors.New("read native catalog; inspect private diagnostics")
	}
	if err = os.WriteFile(filepath.Join(root, "catalog.json"), catalog, 0o600); err != nil {
		return err
	}
	if err = request.CheckCatalog(catalog); err != nil {
		return err
	}
	output, err := runLogged(ctx, execute, log, "/usr/bin/pgbackrest", append(args,
		"--pg1-path="+data, "--set="+request.Set, "--type=immediate", "--target-action=pause", "--archive-mode=off", "restore")...)
	if _, writeErr := log.Write(output); err != nil || writeErr != nil {
		return errors.New("restore incomplete; preserve the attempt and inspect private diagnostics")
	}
	control, err := runLogged(ctx, execute, log, "/usr/lib/postgresql/18/bin/pg_controldata", data)
	if err != nil {
		return errors.New("read restored database identity")
	}
	if controlValue(control, "Database system identifier") != request.SystemID {
		return errors.New("restored database identity differs from the approved source")
	}
	completion := fmt.Sprintf("{\"system_id\":%q,\"set\":%q,\"postgresql_started\":false}\n", request.SystemID, request.Set)
	return os.WriteFile(filepath.Join(root, "files-restored.json"), []byte(completion), 0o600)
}

// reserveAttempt creates the attempt directory root, which must not exist yet, records request in
// it, and opens the attempt's log.
func reserveAttempt(root string, request Request) (*os.File, error) {
	if err := os.Mkdir(root, 0o700); err != nil {
		return nil, errors.New("destination already used or unavailable; inspect without replay")
	}
	requestData, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(filepath.Join(root, "request.json"), requestData, 0o600); err != nil {
		return nil, err
	}
	return os.OpenFile(filepath.Join(root, "restore.log"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
}

// controlValue returns the value pg_controldata printed for key, or "" when it printed none.
func controlValue(control []byte, key string) string {
	for line := range strings.SplitSeq(string(control), "\n") {
		if name, value, _ := strings.Cut(line, ":"); name == key {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

// runLogged runs one native tool of a restore, and adds the standard output of a failed call to log.
func runLogged(ctx context.Context, execute Executor, log io.Writer, name string, args ...string) ([]byte, error) {
	output, err := execute(ctx, log, name, args...)
	if err != nil {
		_, writeErr := log.Write(output)
		err = errors.Join(err, writeErr)
	}
	return output, err
}

// Command executes installed native tools without inherited configuration, proxies or credentials.
// The caller's container supervisor owns process-tree termination after cancellation.
func Command(ctx context.Context, diagnostics io.Writer, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = []string{"PATH=/usr/local/bin:/usr/bin:/bin", "LC_ALL=C", "HOME=/tmp"}
	cmd.Stderr = diagnostics
	cmd.WaitDelay = 5 * time.Second
	return cmd.Output()
}
