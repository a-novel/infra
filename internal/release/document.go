package release

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/santhosh-tekuri/jsonschema/v6"
	"go.yaml.in/yaml/v3"

	"github.com/a-novel/infra/deploy/production"
)

type object = map[string]any

// Compiler uses embedded schemas with format assertions and no external loaders.
type Compiler struct {
	schemas map[string]*jsonschema.Schema
}

// NewCompiler checks the reviewed schemas before accepting private inputs.
func NewCompiler() (*Compiler, error) {
	validator := jsonschema.NewCompiler()
	validator.AssertFormat()
	validator.UseLoader(jsonschema.SchemeURLLoader{})
	compiler := &Compiler{schemas: map[string]*jsonschema.Schema{}}
	for _, file := range []string{"images.schema.json", "receipt.schema.json", "release-config.schema.yaml"} {
		data, err := production.Schemas.ReadFile(file)
		if err != nil {
			return nil, errors.New("embedded schema is unavailable")
		}
		value, err := decode(data, strings.HasSuffix(file, ".yaml"))
		if err != nil {
			return nil, errors.New("embedded schema is invalid")
		}
		id := str(value, "$id")
		if err = validator.AddResource(id, value); err != nil {
			return nil, errors.New("cannot register embedded schema")
		}
		schema, err := validator.Compile(id)
		if err != nil {
			return nil, errors.New("cannot compile embedded schema")
		}
		compiler.schemas[strings.Split(file, ".")[0]] = schema
	}
	return compiler, nil
}

func decode(data []byte, isYAML bool) (any, error) {
	if isYAML {
		var value any
		decoder := yaml.NewDecoder(bytes.NewReader(data))
		if err := decoder.Decode(&value); err != nil {
			return nil, errors.New("invalid YAML")
		}
		var extra any
		if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
			return nil, errors.New("expected one YAML document")
		}
		var err error
		data, err = json.Marshal(value)
		if err != nil {
			return nil, errors.New("YAML must contain JSON-compatible values")
		}
	}
	return jsonschema.UnmarshalJSON(bytes.NewReader(data))
}

func read(file, label string, isYAML bool) (object, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return nil, fmt.Errorf("cannot read %s", label)
	}
	value, err := decode(data, isYAML)
	document, ok := value.(object)
	if err != nil || !ok {
		return nil, fmt.Errorf("%s is invalid", label)
	}
	return document, nil
}

func (compiler *Compiler) validate(name string, value any) error {
	if err := compiler.schemas[name].Validate(value); err != nil {
		// Only the embedded schema location is public; never print instance paths or values.
		var invalid *jsonschema.ValidationError
		if errors.As(err, &invalid) {
			for len(invalid.Causes) > 0 {
				invalid = invalid.Causes[0]
			}
			return fmt.Errorf("%s is invalid at %s", name, invalid.SchemaURL)
		}
		return fmt.Errorf("%s is invalid", name)
	}
	return nil
}

func (compiler *Compiler) load(file, schema string) (object, error) {
	value, err := read(file, schema, schema == "images")
	if err != nil {
		return nil, err
	}
	return value, compiler.validate(schema, value)
}

func at(value any, path ...string) any {
	for _, key := range path {
		mapping, _ := value.(object)
		value = mapping[key]
	}
	return value
}

func obj(value any, path ...string) object {
	result, _ := at(value, path...).(object)
	return result
}

func str(value any, path ...string) string {
	result, _ := at(value, path...).(string)
	return result
}

func copyValue(value any) any {
	switch typed := value.(type) {
	case object:
		result := object{}
		for key, item := range typed {
			result[key] = copyValue(item)
		}
		return result
	case []any:
		result := make([]any, len(typed))
		for index, item := range typed {
			result[index] = copyValue(item)
		}
		return result
	default:
		return value
	}
}

func clone(value object) object { return copyValue(value).(object) }

func hash(value string) string { return fmt.Sprintf("%x", sha256.Sum256([]byte(value))) }

func writePrivate(file string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return errors.New("cannot encode private output")
	}
	output, err := os.OpenFile(file, os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return errors.New("cannot open private output")
	}
	// Tighten an existing file before replacing its contents.
	writeErr := output.Chmod(0o600)
	if writeErr == nil {
		writeErr = output.Truncate(0)
	}
	if writeErr == nil {
		_, writeErr = output.Write(append(data, '\n'))
	}
	closeErr := output.Close()
	if writeErr != nil || closeErr != nil {
		return errors.New("cannot write private output")
	}
	return nil
}

func writeOutputs(directory string, values map[string]any) error {
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return errors.New("cannot create private output directory")
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		return errors.New("cannot secure private output directory")
	}
	for name, value := range values {
		if err := writePrivate(filepath.Join(directory, name), value); err != nil {
			return err
		}
	}
	return nil
}
