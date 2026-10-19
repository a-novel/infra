package recovery

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

//go:embed verify.sql
var verificationSQL string

//go:embed data.sql
var dataSQL string

//go:embed authenticationVerify.sql
var authenticationVerificationSQL string

//go:embed authenticationData.sql
var authenticationDataSQL string

// serviceSQL holds a service's recovery queries.
type serviceSQL struct {
	// schema returns "t" when the restored schema and roles pass the service's checks.
	schema string
	// data returns the SHA-256 digest of the service's application rows.
	data string
}

// recoverySQL holds the queries of every service a recovery accepts.
var recoverySQL = map[string]serviceSQL{
	"json-keys":      {schema: verificationSQL, data: dataSQL},
	"authentication": {schema: authenticationVerificationSQL, data: authenticationDataSQL},
}

// evidence lists the files a completed file restoration leaves in its attempt directory.
var evidence = []string{"request.json", "catalog.json", "files-restored.json"}

// VerifySQL validates restored service data in a separately supervised, networkless
// container. It pauses at backup consistency, preserves failures and refuses replay.
func VerifySQL(ctx context.Context, request Request, parent string, execute func(context.Context, io.Writer, string, ...string) ([]byte, error)) (err error) {
	if request.Validate() != nil || !request.VerifySQL {
		return errors.New("offline SQL verification was not selected")
	}
	root := filepath.Join(parent, "attempt")
	files, err := readEvidence(root)
	if err != nil {
		return err
	}
	if err := request.CheckFiles(files); err != nil {
		return err
	}
	verification := filepath.Join(root, "verification")
	if err := os.Mkdir(verification, 0o700); err != nil {
		return errors.New("SQL verification already attempted or unavailable; inspect without replay")
	}
	log, err := os.OpenFile(filepath.Join(verification, "postgres.log"), os.O_CREATE|os.O_EXCL|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, log.Close()) }()
	data := filepath.Join(root, "data")
	role := "agora_" + strings.ReplaceAll(request.Service, "-", "_")
	if err := configureOffline(data, verification, role); err != nil {
		return err
	}

	const bin = "/usr/lib/postgresql/18/bin/"
	command := func(binary string, args ...string) ([]byte, error) { return execute(ctx, log, bin+binary, args...) }
	stopped := false
	defer func() {
		if !stopped {
			cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 35*time.Second)
			defer cancel()
			_, stopErr := execute(cleanup, log, bin+"pg_ctl", "-D", data, "-m", "fast", "-w", "-t", "30", "stop")
			err = errors.Join(err, stopErr)
		}
	}()
	if _, err := command("pg_ctl", "-D", data, "-l", filepath.Join(verification, "postgres.log"),
		"-o", "-c config_file="+filepath.Join(verification, "postgresql.conf"), "-w", "-t", "60", "start"); err != nil {
		return errors.New("offline PostgreSQL startup failed; inspect private diagnostics")
	}
	query := func(sql string) (string, error) {
		out, err := command("psql", "-XqAt", "-v", "ON_ERROR_STOP=1", "-h", verification, "-U", role, "-d", role, "-c", sql)
		return strings.TrimSpace(string(out)), err
	}
	if err := awaitConsistency(ctx, query, request.SystemID); err != nil {
		return err
	}
	queries := recoverySQL[request.Service]
	checks, err := query(queries.schema)
	if err != nil || checks != "t" {
		return errors.New("service recovery checks failed; inspect private diagnostics")
	}
	result := sqlCompletion{SystemID: request.SystemID, Set: request.Set, Stopped: true}
	if request.ExpectedDataSHA256 != "" {
		result.DataSHA256, err = query(queries.data)
		if err != nil || result.DataSHA256 != request.ExpectedDataSHA256 {
			return errors.New("recovered application data differs from the independent expectation or could not be read")
		}
	}
	if _, err := command("pg_ctl", "-D", data, "-m", "fast", "-w", "-t", "30", "stop"); err != nil {
		return errors.New("verified PostgreSQL shutdown is unconfirmed")
	}
	stopped = true
	outcome, err := json.Marshal(result)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(verification, "sql-verified.json"), outcome, 0o600)
}

// readEvidence reads the evidence files of a completed file restoration.
func readEvidence(root string) (map[string]string, error) {
	files := map[string]string{}
	for _, name := range evidence {
		data, err := os.ReadFile(filepath.Join(root, name))
		if err != nil {
			return nil, errors.New("read completed file restoration before SQL verification")
		}
		files[name] = string(data)
	}
	return files, nil
}

// configureOffline lets only role connect, through a socket in the verification directory, to a
// server that replays the restored WAL to backup consistency and never archives.
func configureOffline(data, verification, role string) error {
	// Retain the restore-generated configuration, but never execute its cloud archive reader.
	if err := os.Rename(filepath.Join(data, "postgresql.auto.conf"), filepath.Join(verification, "restored.auto.conf")); err != nil {
		return err
	}
	config := fmt.Sprintf(`data_directory='%s'
hba_file='%s/pg_hba.conf'
ident_file='%s/pg_ident.conf'
listen_addresses=''
unix_socket_directories='%s'
unix_socket_permissions=0700
shared_buffers='64MB'
archive_mode=off
restore_command='/usr/bin/false'
recovery_target='immediate'
recovery_target_action='pause'
recovery_target_timeline='current'
hot_standby=on
default_transaction_read_only=on
statement_timeout='30s'
`, data, verification, verification, verification)
	files := map[string]string{
		filepath.Join(data, "postgresql.auto.conf"):    "",
		filepath.Join(verification, "postgresql.conf"): config,
		filepath.Join(verification, "pg_hba.conf"):     "local all " + role + " peer map=verification\n",
		filepath.Join(verification, "pg_ident.conf"):   "verification postgres " + role + "\n",
	}
	for path, value := range files {
		file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err != nil {
			return err
		}
		_, writeErr := io.WriteString(file, value)
		if err := errors.Join(writeErr, file.Close()); err != nil {
			return err
		}
	}
	return nil
}

// awaitConsistency waits up to 30 seconds for the server to pause at the recovery target.
// SQL readiness can precede the recovery target. Only the native paused state qualifies.
func awaitConsistency(ctx context.Context, query func(string) (string, error), systemID string) error {
	deadline := time.NewTimer(30 * time.Second)
	defer deadline.Stop()
	for {
		state, err := query("SELECT system_identifier, pg_is_in_recovery(), pg_get_wal_replay_pause_state() FROM pg_control_system();")
		if err != nil || !strings.HasPrefix(state, systemID+"|t|") {
			return errors.New("offline recovery identity or target state differs")
		}
		if state == systemID+"|t|paused" {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			return errors.New("offline recovery did not reach backup consistency")
		case <-time.After(250 * time.Millisecond):
		}
	}
}

// sqlCompletion records a successful SQL verification in sql-verified.json.
type sqlCompletion struct {
	SystemID   string `json:"system_id"`
	Set        string `json:"set"`
	Stopped    bool   `json:"postgresql_stopped"`
	DataSHA256 string `json:"data_sha256,omitempty"`
}
