package isolation

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/a-novel/infra/internal/custody"
	"github.com/a-novel/infra/internal/release"
)

type drill struct {
	execute                                                   func(context.Context, io.Writer, string, ...string) error
	getenv                                                    func(string) string
	operation, target, scratch, project, zone, disk, revision string
	database, selected                                        object
	receipt                                                   []byte
	mutated, attempted, restored, peerUnchanged               bool
}

// Run accepts only the protected manual release workflow. It returns 64 for
// invalid arguments and 70 for unproven results, including failed compensation.
func Run(ctx context.Context, args []string, getenv func(string) string, execute func(context.Context, io.Writer, string, ...string) error, stdout, stderr io.Writer) (code int) {
	stop := func(code int, message string) int {
		_, _ = fmt.Fprintln(stderr, "STOP: "+message) // Best effort on a closed diagnostic stream.
		return code
	}
	if len(args) != 4 || (args[0] != "drill" && args[0] != "restore") || args[2] != strings.ToUpper(args[0])+" authentication" || !matches(`[1-9][0-9]*-[1-9][0-9]*`, args[1]) {
		return stop(64, "Usage: infra database-isolation <drill|restore> <receipt-id> <confirmation> <config-file>")
	}
	if info, err := os.Stat(args[3]); err != nil || !info.Mode().IsRegular() {
		return stop(64, "expected a protected configuration file")
	}
	if !matches(`[a-f0-9]{40}`, getenv("GITHUB_SHA")) || !matches(`[1-9][0-9]*`, getenv("GITHUB_RUN_ID")) || !matches(`[1-9][0-9]*`, getenv("GITHUB_RUN_ATTEMPT")) ||
		getenv("GITHUB_REPOSITORY") != "a-novel/infra" || getenv("GITHUB_EVENT_NAME") != "workflow_dispatch" || getenv("GITHUB_WORKFLOW_REF") != "a-novel/infra/.github/workflows/release.yaml@refs/heads/master" {
		return stop(70, "use the protected master release workflow")
	}
	directory, err := os.MkdirTemp("", "infra-isolation-")
	if err != nil {
		return stop(70, "cannot create private drill workspace")
	}
	d := &drill{execute: execute, getenv: getenv, operation: args[0], target: args[1], scratch: directory, revision: getenv("GITHUB_SHA")}
	started := time.Now().UTC().Format(time.RFC3339)
	defer func() {
		if d.mutated && !d.attempted {
			// Compensation must still run after cancellation, but cannot outlive its own budget.
			cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Minute)
			if err := d.restore(cleanup); err != nil {
				code = stop(70, err.Error()+"; use the protected restore-database-isolation action")
			}
			cancel()
		}
		if file := getenv("GITHUB_STEP_SUMMARY"); file != "" {
			summary := fmt.Sprintf("## Database isolation %s\n\nSource receipt: %s\n\nStarted: %s; finished: %s\n\nExit status: %d; Authentication restored: %t; JSON Keys host unchanged: %t.\n\nConnection continuity requires the human psql probe covering this entire interval. This workflow does not attest SQL continuity.\n", d.operation, d.target, started, time.Now().UTC().Format(time.RFC3339), code, d.restored, d.peerUnchanged)
			output, err := os.OpenFile(file, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
			if err == nil {
				_, err = io.WriteString(output, summary)
				err = errors.Join(err, output.Close())
			}
			if err != nil {
				code = stop(70, "cannot report drill evidence")
			}
		}
		_ = os.RemoveAll(directory) // Best-effort removal of this invocation's private scratch directory.
	}()
	if err = d.run(ctx, args[3]); err != nil {
		return stop(70, err.Error())
	}
	if _, err = fmt.Fprintln(stdout, "PASS Authentication metadata restored; JSON Keys host unchanged. Verify the human connection probe before accepting isolation."); err != nil {
		return stop(70, "cannot report drill result")
	}
	return 0
}

func (d *drill) latest(ctx context.Context) error {
	file := filepath.Join(d.scratch, "latest.json")
	if custody.Run(ctx, []string{"receipt", "latest", d.getenv("RECEIPT_BUCKET"), file}, d.getenv, d.execute, io.Discard, io.Discard) != 0 {
		return errors.New("cannot select the latest successful receipt")
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return errors.New("cannot read selected receipt")
	}
	receipt, err := decode(data)
	if err != nil || text(receipt, "sequence", "runId")+"-"+text(receipt, "sequence", "runAttempt") != d.target || get(receipt, "database", "hosts") == nil || get(receipt, "activeTfvars", "application_release") == nil ||
		(d.receipt != nil && !bytes.Equal(d.receipt, data)) {
		return errors.New("select the latest successful two-host receipt; the selected receipt changed or is unsuitable")
	}
	d.receipt, d.selected = data, receipt
	return nil
}

func (d *drill) compile(config string) error {
	receiptFile, manifest, directory := filepath.Join(d.scratch, "latest.json"), filepath.Join(d.getenv("GITHUB_WORKSPACE"), "deploy/production/images.yaml"), filepath.Join(d.scratch, "compiled")
	if d.operation == "restore" {
		manifest = filepath.Join(d.scratch, "images.json")
		if err := write(manifest, d.selected["imageManifest"]); err != nil {
			return err
		}
	}
	compiler, err := release.NewCompiler()
	if err != nil {
		return err
	}
	attempt, _ := strconv.Atoi(d.getenv("GITHUB_RUN_ATTEMPT")) // Compiler identity validation rejects parse failures.
	identity := release.Identity{Commit: d.revision, RunID: d.getenv("GITHUB_RUN_ID"), RunAttempt: attempt, Nonce: rand.Text()}
	if err = compiler.CompileRelease([]string{manifest, config, receiptFile, directory}, identity, "deploy", "", receiptFile); err != nil {
		return err
	}
	data, err := os.ReadFile(filepath.Join(directory, "release.json"))
	if err != nil {
		return errors.New("cannot read compiled drill inputs")
	}
	compiled, err := decode(data)
	if err != nil || compiled["action"] != "deploy" || compiled["mode"] != "maintenance" || !reflect.DeepEqual(compiled["database"], compiled["previousDatabase"]) ||
		!reflect.DeepEqual(compiled["database"], compiled["currentDatabase"]) || !reflect.DeepEqual(compiled["imageManifest"], compiled["previousManifest"]) {
		return errors.New("deploy pending image or database configuration changes separately from this drill")
	}
	d.project, d.zone = text(compiled, "cloud", "workloadProjectId"), text(compiled, "cloud", "databaseZone")
	d.disk = text(compiled, "cloud", "databaseHosts", "authentication", "data_disk_id")
	d.database, _ = compiled["previousDatabase"].(object)
	return write(filepath.Join(d.scratch, "database.json"), d.database)
}

func (d *drill) run(ctx context.Context, config string) error {
	if err := d.latest(ctx); err != nil {
		return err
	}
	if err := d.compile(config); err != nil {
		return err
	}
	auth, err := d.inspect(ctx, "authentication")
	if err != nil {
		return err
	}
	peer, err := d.inspect(ctx, "json-keys")
	if err != nil {
		return err
	}
	if !peer.healthy(d.metadata("json-keys")) {
		return errors.New("JSON Keys differs from the selected healthy receipt")
	}
	expected := d.metadata("authentication")
	args := []string{d.project, d.zone, "authentication", d.disk}
	if d.operation == "drill" {
		if d.revision == text(expected, revisionKey) || !auth.healthy(expected) {
			return errors.New("authentication must match the healthy receipt and use a distinct drill revision")
		}
		if _, err = d.command(ctx, "./ops/preflight-release.sh", filepath.Join(d.scratch, "compiled/release.json")); err != nil {
			return err
		}
		metadata, err := json.Marshal(expected)
		if err != nil {
			return errors.New("cannot bind drill metadata")
		}
		if _, err = d.command(ctx, "./ops/prepare-database-change.sh", append(args, d.revision, filepath.Join(d.scratch, "proof.json"), fmt.Sprintf("%x", sha256.Sum256(metadata)))...); err != nil {
			return err
		}
	} else if !sameConfiguration(auth.Metadata, expected) {
		return errors.New("restore refuses image, credential, or metadata-shape drift")
	}
	if err = d.latest(ctx); err != nil {
		return err
	}
	if err = d.checkPeer(ctx, peer); err != nil {
		return err
	}
	if d.operation == "drill" {
		d.mutated = true // A failed provider response may still have changed live metadata.
		command := append([]string{"DATABASE_CHANGE_PROOF=" + filepath.Join(d.scratch, "proof.json"), "./ops/deploy-database-release.sh"}, args...)
		command = append(command, d.revision, text(d.database, "authenticationImage"), text(d.database, "authenticationPasswordVersion"), text(d.database, "authenticationBackupPasswordVersion"))
		if _, err = d.command(ctx, "env", command...); err != nil {
			return errors.New("authentication restart failed")
		}
		if err = d.checkPeer(ctx, peer); err != nil {
			return err
		}
	}
	if err = d.restore(ctx); err != nil {
		return fmt.Errorf("%w; use the protected restore-database-isolation action", err)
	}
	after, err := d.inspect(ctx, "authentication")
	if err != nil {
		return err
	}
	if !after.healthy(expected) {
		return errors.New("authentication did not restore the receipt metadata and health")
	}
	auth.Metadata, after.Metadata, auth.Started, after.Started, auth.Guest, after.Guest = nil, nil, "", "", "", ""
	if !reflect.DeepEqual(auth, after) {
		return errors.New("authentication host or disks changed during restoration")
	}
	if err = d.checkPeer(ctx, peer); err != nil {
		return err
	}
	d.peerUnchanged = true
	return nil
}

func (d *drill) restore(ctx context.Context) error {
	d.attempted = true
	group, err := d.group(ctx, "authentication")
	actual, _ := get(group, "allInstancesConfig", "properties", "metadata").(object)
	expected := d.metadata("authentication")
	if err != nil || !sameConfiguration(actual, expected) || (d.operation != "restore" && text(actual, revisionKey) != text(expected, revisionKey) && text(actual, revisionKey) != d.revision) {
		return errors.New("restoration refuses unexpected live metadata")
	}
	if _, err = d.command(ctx, "./ops/restore-database-release.sh", d.project, d.zone, "authentication", d.disk, filepath.Join(d.scratch, "database.json")); err != nil {
		return err
	}
	d.restored, d.mutated = true, false
	return nil
}

func (d *drill) command(ctx context.Context, name string, args ...string) ([]byte, error) {
	var output bytes.Buffer
	if err := d.execute(ctx, &output, name, args...); err != nil {
		return nil, fmt.Errorf("%s failed; inspect the protected operation", filepath.Base(name))
	}
	return output.Bytes(), nil
}

func matches(pattern, value string) bool {
	return regexp.MustCompile("^(?:" + pattern + ")$").MatchString(value)
}
