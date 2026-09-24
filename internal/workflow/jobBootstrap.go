package workflow

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

type foundationObject struct {
	URI, SHA256 string
}

// foundationSource authorizes the download before the workflow has credentials.
// HCL owns the downloaded document's runtime and database contract validation.
func foundationSource(config map[string]json.RawMessage, bucket, scope string) (foundationObject, error) {
	invalid := errors.New("invalid approved foundation reference")
	var reference map[string]json.RawMessage
	if json.Unmarshal(config["foundation"], &reference) != nil || config["foundation_json"] != nil {
		return foundationObject{}, invalid
	}
	var schema int
	if json.Unmarshal(reference["schema_version"], &schema) != nil || schema != 1 {
		return foundationObject{}, invalid
	}
	fields := make(map[string]string, 4)
	for _, key := range []string{"bucket", "object", "generation", "sha256"} {
		var value string
		if json.Unmarshal(reference[key], &value) != nil || value == "" {
			return foundationObject{}, invalid
		}
		fields[key] = value
	}
	if fields["bucket"] != bucket || !matches(`[a-f0-9]{64}`, fields["sha256"]) || !matches(`[1-9][0-9]*`, fields["generation"]) {
		return foundationObject{}, invalid
	}
	object := "foundation/coordinates/" + strings.TrimPrefix(scope, "services/") + "/" + fields["sha256"] + ".json"
	if fields["object"] != object {
		return foundationObject{}, invalid
	}
	return foundationObject{"gs://" + bucket + "/" + object + "#" + fields["generation"], fields["sha256"]}, nil
}

func bindFoundation(args []string, getenv func(string) string, stdout io.Writer) error {
	invalid := errors.New("invalid job bootstrap inputs")
	if getenv("SERVICE_JOB_BOOTSTRAP_ENABLED") != "true" || args[2] == "" || strings.ContainsAny(args[2], "\r\n") {
		return invalid
	}
	data, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	scope, err := serviceFoundationScope(data, getenv, getenv("STATE_BUCKET"))
	if err != nil {
		return err
	}
	var config map[string]json.RawMessage
	if json.Unmarshal(data, &config) != nil {
		return invalid
	}
	source, err := foundationSource(config, getenv("STATE_BUCKET"), scope)
	if err != nil {
		return err
	}
	coordinates, err := os.ReadFile(args[1])
	if err != nil {
		return err
	}
	checksum := fmt.Sprintf("%x", sha256.Sum256(coordinates))
	if checksum != source.SHA256 || !json.Valid(coordinates) {
		return invalid
	}
	config["foundation_json"], err = json.Marshal(string(coordinates))
	if err != nil {
		return err
	}
	data, err = json.Marshal(config)
	if err != nil {
		return err
	}
	return writeFoundationInputs(args[2], data, stdout, scope)
}
