package release

import (
	"fmt"
	"io"
)

// Run validates image transitions or historical receipts without cloud access.
// Diagnostics identify invalid contracts without exposing private inputs.
func Run(args []string, stdout, stderr io.Writer) int {
	stop := func(code int, message string) int {
		_, _ = fmt.Fprintln(stderr, message) // Best effort if the diagnostic stream has closed.
		return code
	}
	usage := "Usage: infra validate-images <previous> <next> | receipt validate <file>"
	if len(args) != 3 || (args[0] != "validate-images" && (args[0] != "receipt" || args[1] != "validate")) {
		return stop(64, usage)
	}
	validator, err := newValidator()
	if err != nil {
		return stop(65, err.Error())
	}
	if args[0] == "receipt" {
		_, err = validator.load(args[2], "receipt")
	} else {
		var previous, next object
		previous, err = validator.load(args[1], "images")
		if err == nil {
			next, err = validator.load(args[2], "images")
		}
		if err == nil {
			err = familyVersions(next)
		}
		if err == nil {
			err = versionInputs(next)
		}
		if err == nil {
			_, err = imageChanges(previous, next)
		}
	}
	if err != nil {
		return stop(65, err.Error())
	}
	if args[0] != "receipt" {
		if _, err = fmt.Fprintln(stdout, "Private release input checks passed."); err != nil {
			return stop(70, "Cannot report release input checks.")
		}
	}
	return 0
}
