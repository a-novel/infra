package database

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

func metadataHash(metadata map[string]string) string {
	var data bytes.Buffer
	encoder := json.NewEncoder(&data)
	encoder.SetEscapeHTML(false)
	_ = encoder.Encode(metadata) // A string map cannot fail JSON encoding.
	return fmt.Sprintf("%x", sha256.Sum256(bytes.TrimSuffix(data.Bytes(), []byte("\n"))))
}

func (h host) prepare(ctx context.Context, revision, proof, expected string) error {
	if err := h.checkDisk(ctx); err != nil {
		return err
	}
	metadata, err := h.liveMetadata(ctx)
	if err != nil {
		return err
	}
	hash := metadataHash(metadata)
	if expected != "" && expected != hash {
		return failure{70, "database metadata differs from the latest immutable receipt"}
	}
	if err = h.snapshot(ctx); err != nil {
		return err
	}
	if metadata[revisionKey] != "" {
		if _, err = h.command(ctx, "run", "jobs", "execute", "agora-postgres-backup-"+h.service, "--project="+h.project, "--region="+h.region(), "--wait", "--quiet", "--format=none"); err != nil {
			return failure{70, "required pre-change PostgreSQL backup failed"}
		}
	}
	if proof == "" {
		return nil
	}
	data := object{"project": h.project, "zone": h.zone, "service": h.service, "dataDiskId": h.disk, "revision": revision, "currentMetadataSha256": hash, "checkedAt": time.Now().Unix()}
	file, err := os.CreateTemp(filepath.Dir(proof), ".database-proof-*")
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(file.Name()) }() // Rename may already have removed this path.
	if err = errors.Join(json.NewEncoder(file).Encode(data), file.Close()); err != nil {
		return err
	}
	return os.Rename(file.Name(), proof)
}

func (h host) checkProof(ctx context.Context, file, revision string) error {
	proof, err := read(file)
	now := time.Now().Unix()
	checked, ok := get(proof, "checkedAt").(json.Number)
	at, parseErr := checked.Int64()
	if err != nil || len(proof) != 7 || !ok || parseErr != nil || at < now-600 || at > now+30 ||
		get(proof, "project") != h.project || get(proof, "zone") != h.zone || get(proof, "service") != h.service ||
		get(proof, "dataDiskId") != h.disk || get(proof, "revision") != revision || !matches(`[a-f0-9]{64}`, text(proof, "currentMetadataSha256")) {
		return failure{70, "database preparation proof is invalid or stale"}
	}
	metadata, err := h.liveMetadata(ctx)
	if err != nil {
		return err
	}
	if metadataHash(metadata) != get(proof, "currentMetadataSha256") {
		return failure{70, "database metadata changed after preparation"}
	}
	return nil
}

func (h host) snapshot(ctx context.Context) error {
	data, err := h.command(ctx, "compute", "snapshots", "list", "--project="+h.project,
		"--filter=labels.application=agora AND labels.environment=production AND labels.role=database-snapshot AND labels.component="+h.service,
		"--sort-by=~creationTimestamp", "--limit=1", "--format=json(name,autoCreated,sourceDisk,sourceDiskId,status,creationTimestamp,storageLocations,labels)")
	var snapshots []struct {
		AutoCreated                           bool
		Status, SourceDisk, CreationTimestamp string
		SourceDiskID                          json.Number
		StorageLocations                      []string
		Labels                                map[string]string
	}
	if err != nil || json.Unmarshal([]byte(data), &snapshots) != nil || len(snapshots) != 1 {
		return failure{70, "no valid scheduled database snapshot is ready"}
	}
	snapshot := snapshots[0]
	if !snapshot.AutoCreated || snapshot.Status != "READY" || string(snapshot.SourceDiskID) != h.disk ||
		!strings.HasSuffix(snapshot.SourceDisk, "/projects/"+h.project+"/zones/"+h.zone+"/disks/agora-data-"+h.service) || !slices.Contains(snapshot.StorageLocations, h.region()) {
		return failure{70, "snapshot does not identify the selected scheduled disk backup"}
	}
	for key, value := range map[string]string{"component": h.service, "application": "agora", "environment": "production", "managed-by": "opentofu", "plane": "workload", "role": "database-snapshot"} {
		if snapshot.Labels[key] != value {
			return failure{70, "snapshot labels differ from the scheduled backup"}
		}
	}
	created, err := time.Parse(time.RFC3339Nano, snapshot.CreationTimestamp)
	age := time.Now().Unix() - created.Unix()
	if err != nil || age < -300 || age > 93600 {
		return failure{70, "scheduled snapshot is outside the 26-hour change window"}
	}
	return nil
}
