package database

import (
	"context"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"google.golang.org/api/compute/v1"

	"github.com/a-novel/infra/internal/recovery"
)

//go:embed nativeBackup.sh
var nativeBackupScript string

//go:embed nativeRestore.sh
var nativeRestoreScript string

// nativeProof checks a fresh backup before maintenance without adding recovery capacity.
// Uncertain SSH outcomes are never replayed; the caller retains its admission hold.
func (target maintenanceTarget) nativeProof(ctx context.Context, execute func(context.Context, io.Writer, string, ...string) error, directory string) (object, error) {
	h := target.host(execute)
	name := "agora-pgbackrest-" + target.Service
	data, err := h.compute(ctx, "instances", "describe", name, "--format=json")
	var repository compute.Instance
	if err != nil || json.Unmarshal([]byte(data), &repository) != nil || repository.Name != name || repository.Id == 0 || repository.Status != "RUNNING" ||
		len(repository.NetworkInterfaces) != 1 || len(repository.NetworkInterfaces[0].AccessConfigs) != 0 || len(repository.NetworkInterfaces[0].Ipv6AccessConfigs) != 0 ||
		repository.Labels["component"] != target.Service || repository.Labels["role"] != "backup-repository" {
		return nil, failure{70, "private native repository host is unconfirmed"}
	}
	digest := strings.Split(target.Metadata["agora-"+target.Service+"-database-image"], "@sha256:")
	if len(digest) != 2 || !matches(`[a-f0-9]{64}`, digest[1]) {
		return nil, failure{65, "native maintenance database digest is invalid"}
	}
	keyDirectory, err := os.MkdirTemp(directory, "native-key-")
	if err != nil {
		return nil, failure{70, "native maintenance key directory is unavailable"}
	}
	defer func() { _ = os.RemoveAll(keyDirectory) }() // The parent custody scratch also removes failed cleanup.
	key := filepath.Join(keyDirectory, "identity")
	// Preparing the key separately keeps gcloud's key-generation banner out of the catalog.
	if err := execute(ctx, io.Discard, "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key); err != nil {
		return nil, failure{70, "native maintenance key generation failed; no host changed"}
	}
	started := time.Now()
	data, err = h.nativeSSH(ctx, key, target.Instance, nativeBackupScript, target.Service, target.InstanceID, digest[1])
	writeErr := os.WriteFile(filepath.Join(directory, "native-backup-"+target.Service+".txt"), []byte(data), 0o600)
	if err != nil || writeErr != nil {
		return nil, failure{70, "fresh native backup failed or is uncertain; no host changed"}
	}
	systemID, catalog, ok := strings.Cut(data, "\n")
	if !ok || !matches(`[1-9][0-9]{0,19}`, systemID) {
		return nil, failure{70, "native backup source identity is unavailable"}
	}
	// Select only a full backup actually completed during this operation, not an old
	// catalog success or the output of a concurrent timer before this operation.
	var stanzas []struct {
		Backup []struct {
			Label     string
			Type      string
			Timestamp struct{ Start, Stop int64 }
			Info      struct{ Size int64 }
		}
	}
	if json.Unmarshal([]byte(catalog), &stanzas) != nil || len(stanzas) != 1 {
		return nil, failure{70, "native backup catalog is invalid"}
	}
	label, size := "", int64(0)
	for _, backup := range stanzas[0].Backup {
		if backup.Type == "full" && backup.Timestamp.Start >= started.Unix() && backup.Timestamp.Stop >= backup.Timestamp.Start && backup.Timestamp.Stop <= time.Now().Unix()+30 {
			if label != "" {
				return nil, failure{70, "native backup selection is ambiguous"}
			}
			label, size = backup.Label, backup.Info.Size
		}
	}
	request := recovery.Request{Service: target.Service, SystemID: systemID, Set: label, Major: 18}
	if !matches(`[0-9]{8}-[0-9]{6}F`, label) || size <= 0 || size >= 2<<30 || request.CheckCatalog([]byte(catalog)) != nil {
		return nil, failure{70, "fresh native backup identity or existing scratch capacity is unconfirmed"}
	}
	schema, err := recovery.VerificationSQL(target.Service)
	if err != nil {
		return nil, err
	}
	repositoryID := strconv.FormatUint(repository.Id, 10)
	data, err = h.nativeSSH(ctx, key, name, nativeRestoreScript, target.Service, repositoryID, label, systemID, digest[1], strconv.FormatInt(size, 10), base64.StdEncoding.EncodeToString([]byte(schema)))
	writeErr = os.WriteFile(filepath.Join(directory, "native-restore-"+target.Service+".txt"), []byte(data), 0o600)
	if err != nil || writeErr != nil || !strings.HasSuffix(data, "sql-verified:"+systemID+":"+label) {
		return nil, failure{70, "isolated native SQL restoration failed or is uncertain; no host changed"}
	}
	return object{"set": label, "systemId": systemID, "repositoryInstanceId": repositoryID, "sqlVerified": true, "completedAt": time.Now().UTC().Format(time.RFC3339)}, nil
}

// nativeSSH sends reviewed host code through IAP using an operation-local OS Login key.
// Arguments are quoted independently, and each script rechecks the endpoint incarnation.
func (h host) nativeSSH(ctx context.Context, key, name, script string, args ...string) (string, error) {
	quote := func(value string) string { return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'" }
	command := "sudo -n timeout --signal=INT 3900s /bin/bash -c " + quote(script) + " bash"
	for _, arg := range args {
		command += " " + quote(arg)
	}
	return h.command(ctx, "compute", "ssh", name, "--project="+h.project, "--billing-project="+h.project, "--zone="+h.zone,
		"--quiet", "--tunnel-through-iap", "--ssh-key-expire-after=1h", "--ssh-key-file="+key,
		"--ssh-flag=-o ConnectTimeout=15", "--command="+command)
}
