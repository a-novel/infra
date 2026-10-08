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

// schemaCheck returns the service's schema check.
func schemaCheck(service string) (string, error) {
	switch service {
	case "json-keys":
		return verificationSQL, nil
	case "authentication":
		return authenticationVerificationSQL, nil
	default:
		return "", errors.New("unsupported service verification")
	}
}

// VerifySQL validates restored service data in a separately supervised, networkless
// container. It pauses at backup consistency, preserves failures and refuses replay.
func VerifySQL(ctx context.Context, request Request, parent string, execute func(context.Context, io.Writer, string, ...string) ([]byte, error)) (err error) {
	if request.Validate() != nil || !request.VerifySQL {
		return errors.New("offline SQL verification was not selected")
	}
	role := "agora_" + strings.ReplaceAll(request.Service, "-", "_")
	verificationQuery, err := schemaCheck(request.Service)
	if err != nil {
		return err
	}
	dataQuery := dataSQL
	if request.Service == "authentication" {
		dataQuery = authenticationDataSQL
	}
	root := filepath.Join(parent, "attempt")
	files := map[string]string{}
	for _, name := range []string{"request.json", "catalog.json", "files-restored.json"} {
		data, readErr := os.ReadFile(filepath.Join(root, name))
		if readErr != nil {
			return errors.New("read completed file restoration before SQL verification")
		}
		files[name] = string(data)
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
	for path, value := range map[string]string{
		filepath.Join(data, "postgresql.auto.conf"):    "",
		filepath.Join(verification, "postgresql.conf"): config,
		filepath.Join(verification, "pg_hba.conf"):     "local all " + role + " peer map=verification\n",
		filepath.Join(verification, "pg_ident.conf"):   "verification postgres " + role + "\n",
	} {
		file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err != nil {
			return err
		}
		_, writeErr := io.WriteString(file, value)
		if err := errors.Join(writeErr, file.Close()); err != nil {
			return err
		}
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
	// SQL readiness can precede the recovery target. Only the native paused state qualifies.
	deadline := time.NewTimer(30 * time.Second)
	defer deadline.Stop()
	for {
		state, err := query("SELECT system_identifier, pg_is_in_recovery(), pg_get_wal_replay_pause_state() FROM pg_control_system();")
		if err != nil || !strings.HasPrefix(state, request.SystemID+"|t|") {
			return errors.New("offline recovery identity or target state differs")
		}
		if state == request.SystemID+"|t|paused" {
			break
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			return errors.New("offline recovery did not reach backup consistency")
		case <-time.After(250 * time.Millisecond):
		}
	}
	checks, err := query(verificationQuery)
	if err != nil || checks != "t" {
		return errors.New("service recovery checks failed; inspect private diagnostics")
	}
	result := sqlCompletion{SystemID: request.SystemID, Set: request.Set, Stopped: true}
	if request.ExpectedDataSHA256 != "" {
		result.DataSHA256, err = query(dataQuery)
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

type sqlCompletion struct {
	SystemID   string `json:"system_id"`
	Set        string `json:"set"`
	Stopped    bool   `json:"postgresql_stopped"`
	DataSHA256 string `json:"data_sha256,omitempty"`
}
