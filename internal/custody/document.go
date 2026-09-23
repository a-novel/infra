package custody

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/a-novel/infra/internal/release"
)

func (storage store) document(kind, action string, args []string, stateSuffix string) error {
	prefix, suffix := "gs://"+storage.bucket+"/production/success", ".json"
	if kind == "config" {
		if len(args) == 0 || (!rootPattern.MatchString(args[0]) && args[0] != "service-release") {
			return failure{65, "Invalid configuration root."}
		}
		prefix, suffix = "gs://"+storage.bucket+"/"+args[0]+"/config", ".tfvars.json"
		if args[0] == "service-foundation" || args[0] == "service-release" {
			if !serviceScopePattern.MatchString(stateSuffix) {
				return failure{65, "Invalid private custody scope."}
			}
			prefix = "gs://" + storage.bucket + "/foundation/" + stateSuffix + "/config"
			if args[0] == "service-release" {
				if action != "fetch" {
					return failure{65, "Service release configuration is inspection-only."}
				}
				prefix = "gs://" + storage.bucket + "/" + stateSuffix + "/release/config"
			}
		}
		args = args[1:]
		if action == "fetch" {
			action = "latest"
		} else if action != "publish" {
			return failure{64, "Unknown configuration custody action."}
		}
	}
	count := map[string]int{"latest": 1, "fetch": 2, "publish": 3}[action]
	if count == 0 || len(args) != count || args[0] == "" {
		return failure{64, "Invalid document custody arguments."}
	}
	uri, sequence := "", ""
	var err error
	if action != "latest" {
		sequence = strings.Join(args[1:], "-")
		name, nameErr := sequenceName(sequence, suffix)
		if nameErr != nil {
			return nameErr
		}
		uri = prefix + "/" + name
	}
	if action == "latest" || (kind == "receipt" && action == "publish") {
		latest, latestErr := storage.latest(prefix, suffix)
		if latestErr != nil && (action != "publish" || !errors.Is(latestErr, failure{4, ""})) {
			return latestErr
		}
		if action == "latest" {
			uri = latest
		} else if latest > uri {
			return failure{70, "A newer production release receipt already exists."}
		}
	}
	var data []byte
	if action == "publish" {
		data, err = os.ReadFile(args[0])
	} else {
		data, err = storage.download(uri)
	}
	if err != nil {
		return failure{70, "Private document could not be read."}
	}
	if err = storage.validateDocument(kind, data, sequence, action == "publish"); err != nil {
		return err
	}
	if action != "publish" {
		return writePrivate(args[0], data)
	}
	if err = storage.upload(uri, data); err != nil {
		// A create may commit even when its response is lost. Only receipts permit
		// reuse, and only when the immutable object has exactly the same bytes.
		if kind == "receipt" {
			if existing, readErr := storage.download(uri); readErr == nil && bytes.Equal(existing, data) {
				return nil
			}
		}
		return failure{70, "Immutable private document could not be created."}
	}
	return nil
}

func (storage store) validateDocument(kind string, data []byte, sequence string, publishing bool) error {
	var value map[string]json.RawMessage
	if json.Unmarshal(data, &value) != nil || value == nil {
		return failure{65, "Invalid private document."}
	}
	if kind == "config" {
		return nil
	}
	file := filepath.Join(storage.scratch, "receipt.json")
	if err := os.WriteFile(file, data, 0o600); err != nil {
		return err
	}
	if release.Run([]string{"receipt", "validate", file}, func(string) string { return "" }, io.Discard, io.Discard) != 0 {
		return failure{65, "Invalid production receipt."}
	}
	if publishing {
		var identity struct {
			RunID      string `json:"runId"`
			RunAttempt int    `json:"runAttempt"`
		}
		if json.Unmarshal(value["sequence"], &identity) != nil || identity.RunID+"-"+strconv.Itoa(identity.RunAttempt) != sequence {
			return failure{65, "Receipt sequence does not match this workflow run."}
		}
	}
	return nil
}
