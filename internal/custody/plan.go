package custody

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"regexp"
	"strconv"
	"time"
)

type metadata struct {
	SchemaVersion int     `json:"schemaVersion"`
	Root          string  `json:"root"`
	Commit        string  `json:"commit"`
	PlanID        string  `json:"planId"`
	StateSuffix   *string `json:"stateSuffix"`
	SHA256        string  `json:"sha256"`
	CreatedEpoch  int64   `json:"createdEpoch"`
	ExpiresEpoch  int64   `json:"expiresEpoch"`
	Destructive   *bool   `json:"destructive"`
}

func (storage store) plan(action string, args []string, suffix string) error {
	count := map[string]int{"publish": 5, "fetch": 4, "consume": 3}[action]
	if count == 0 || len(args) != count || (len(args) > 3 && args[3] == "") {
		return failure{64, "Invalid plan custody arguments."}
	}
	if !rootPattern.MatchString(args[0]) || !regexp.MustCompile(`^[a-f0-9]{40}$`).MatchString(args[1]) ||
		!sequencePattern.MatchString(args[2]) || (suffix != "" && !regexp.MustCompile(`^recovery/[a-z0-9][a-z0-9-]{0,62}$`).MatchString(suffix)) {
		return failure{65, "Invalid plan custody scope."}
	}
	prefix := "gs://" + storage.bucket + "/" + args[0] + "/plans/"
	if suffix != "" {
		prefix += suffix + "/"
	}
	prefix += args[1] + "/" + args[2] + "/"
	planURI, metadataURI := prefix+"plan.tfplan", prefix+"metadata.json"
	now := time.Now().Unix()
	switch action {
	case "consume":
		if err := storage.cloud(io.Discard, "rm", planURI, metadataURI, "--quiet"); err != nil {
			return failure{70, "Reviewed plan could not be consumed; apply remains blocked."}
		}
	case "publish":
		if args[4] != "true" && args[4] != "false" {
			return failure{64, "Publish requires an exact true/false destructive marker."}
		}
		data, err := os.ReadFile(args[3])
		if err != nil {
			return failure{64, "Publish requires a readable plan file."}
		}
		destructive := args[4] == "true"
		meta := metadata{1, args[0], args[1], args[2], &suffix, fmt.Sprintf("%x", sha256.Sum256(data)), now, now + 86400, &destructive}
		encoded, err := json.Marshal(meta)
		if err != nil {
			return err
		}
		if err = storage.upload(planURI, data); err != nil {
			return failure{70, "Private plan already exists or could not be stored."}
		}
		if err = storage.upload(metadataURI, encoded); err != nil {
			_ = storage.cloud(io.Discard, "rm", planURI, "--quiet") // Best effort; metadata failure still blocks apply.
			return failure{70, "Private plan metadata already exists or could not be stored."}
		}
	case "fetch":
		encoded, err := storage.download(metadataURI)
		if err != nil {
			return failure{66, "Reviewed plan metadata is unavailable."}
		}
		var meta metadata
		decoder := json.NewDecoder(bytes.NewReader(encoded))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&meta) != nil || decoder.Decode(new(any)) != io.EOF || meta.SchemaVersion != 1 ||
			meta.Root != args[0] || meta.Commit != args[1] || meta.PlanID != args[2] || meta.StateSuffix == nil || *meta.StateSuffix != suffix ||
			meta.Destructive == nil || meta.CreatedEpoch > now+300 || meta.ExpiresEpoch != meta.CreatedEpoch+86400 || now >= meta.ExpiresEpoch {
			return failure{77, "Reviewed plan is stale or does not match this commit and root."}
		}
		data, err := storage.download(planURI)
		if err != nil {
			return failure{66, "Reviewed opaque plan is unavailable."}
		}
		if meta.SHA256 != fmt.Sprintf("%x", sha256.Sum256(data)) {
			return failure{77, "Reviewed plan hash does not match its private metadata."}
		}
		if err = writePrivate(args[3]+".destructive", []byte(strconv.FormatBool(*meta.Destructive)+"\n")); err != nil {
			return err
		}
		return writePrivate(args[3], data)
	}
	return nil
}
