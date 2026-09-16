package release

import (
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"strconv"
	"time"
)

// Run handles cloud-blind release tooling. It returns 64 for usage errors, 65 for
// rejected inputs, and 70 if the result cannot be reported. Diagnostics omit payloads.
func Run(args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	stop := func(code int, message string) int {
		_, _ = fmt.Fprintln(stderr, message) // Best effort if the diagnostic stream has closed.
		return code
	}
	usage := "Usage: infra compile-release <manifest> <config> <prior-or-> <output-dir> | compile-recovery <foundation-config> <receipt> <outputs-or-> <project> <json-attempt> <auth-attempt> <foundation|release> <output-dir> | validate-images <previous> <next> | receipt <validate|build> ..."
	if len(args) == 0 {
		return stop(64, usage)
	}
	command, files := args[0], args[1:]
	switch command {
	case "compile-release":
		if len(files) != 4 {
			return stop(64, usage)
		}
	case "compile-recovery":
		if len(files) != 8 {
			return stop(64, usage)
		}
	case "validate-images":
		if len(files) != 2 {
			return stop(64, usage)
		}
	case "receipt":
		if len(files) == 0 || (files[0] == "validate" && len(files) != 2) || (files[0] == "build" && len(files) != 6) || (files[0] != "validate" && files[0] != "build") {
			return stop(64, usage)
		}
	default:
		return stop(64, usage)
	}
	compiler, err := NewCompiler()
	if err != nil {
		return stop(65, err.Error())
	}
	identity := Identity{Commit: getenv("GITHUB_SHA"), RunID: getenv("GITHUB_RUN_ID"), Nonce: rand.Text()}
	identity.RunAttempt, _ = strconv.Atoi(getenv("GITHUB_RUN_ATTEMPT")) // Identity validation rejects zero on parse failure.
	switch command {
	case "compile-release":
		action := getenv("RELEASE_ACTION")
		if action == "" {
			action = "deploy"
		}
		err = compiler.CompileRelease(files, identity, action, getenv("PRIOR_IMAGE_MANIFEST"), getenv("CURRENT_RECEIPT"))
	case "compile-recovery":
		err = compiler.CompileRecovery(files, identity)
	case "validate-images":
		var previous, next object
		previous, err = compiler.load(files[0], "images")
		if err == nil {
			next, err = compiler.load(files[1], "images")
		}
		if err == nil {
			err = familyVersions(next)
		}
		if err == nil {
			_, err = imageChanges(previous, next)
		}
	case "receipt":
		if files[0] == "validate" {
			_, err = compiler.load(files[1], "receipt")
		} else {
			err = compiler.BuildReceipt(files[1:], time.Now())
		}
	}
	if err != nil {
		return stop(65, err.Error())
	}
	// Receipt custody has no stdout contract; its callers inspect private files.
	if command != "receipt" {
		if _, err = fmt.Fprintln(stdout, "Private release input checks passed."); err != nil {
			return stop(70, "Cannot report release input checks.")
		}
	}
	return 0
}

// BuildReceipt binds execution evidence to the exact inputs that were deployed.
// Arguments are kind, release inputs, active tfvars, operations, and output path.
func (compiler *Compiler) BuildReceipt(args []string, now time.Time) error {
	if len(args) != 5 || (args[0] != "deployment" && args[0] != "rollback") {
		return errors.New("invalid receipt construction arguments")
	}
	values := make([]object, 3)
	for index := range values {
		value, err := read(args[index+1], "receipt input", false)
		if err != nil {
			return err
		}
		values[index] = value
	}
	release := values[0]
	receipt := object{
		"schemaVersion": 1, "kind": args[0], "createdAt": now.UTC().Format(time.RFC3339),
		"sequence":     object{"runId": release["runId"], "runAttempt": release["runAttempt"]},
		"source":       object{"commit": release["commit"], "manifestSha256": release["manifestSha256"]},
		"activeTfvars": values[1], "database": release["database"], "operations": values[2],
	}
	if release["imageManifest"] != nil {
		receipt["imageManifest"] = release["imageManifest"]
	}
	if err := compiler.validate("receipt", receipt); err != nil {
		return err
	}
	return writePrivate(args[4], receipt)
}
