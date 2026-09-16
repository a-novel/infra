package workflow

import (
	"errors"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

const usage = `usage: go run ./cmd/infra
  drift
  drift assess-pull-request <pull-request-number>
  foundation plan <bootstrap|foundation>
  foundation apply <bootstrap|foundation> <plan-id>
  release deploy [--no-wait]
  release rollback <receipt-id>
  release recover-first-launch <failed-run-id>
  release drill-database-isolation <receipt-id> 'DRILL authentication'
  release restore-database-isolation <receipt-id> 'RESTORE authentication'
  recovery plan-workload <replacement-project-id> <receipt-id>
  recovery apply-workload <replacement-project-id> <receipt-id> <plan-id>
  recovery restore-data <replacement-project-id> <receipt-id> <json-keys-attempt> <authentication-attempt> <lost-write-window> <confirmation>
  recovery cleanup-project <replacement-project-id> <receipt-id> <confirmation>`

type intent struct {
	workflow, planID, planPrefix, pullRequest string
	inputs                                    []string
	attempt, noWait                           bool
}

func (i *intent) input(key, value string) {
	i.inputs = append(i.inputs, "-f", "inputs["+key+"]="+value)
}

func matches(pattern, value string) bool {
	return regexp.MustCompile("^(?:" + pattern + ")$").MatchString(value)
}

func parse(args []string) (intent, error) {
	i := intent{}
	invalid := errors.New(usage)
	if len(args) == 0 {
		return i, invalid
	}
	surface, args := args[0], args[1:]
	i.workflow = surface + ".yaml"
	const runID = `[1-9][0-9]*`
	const attemptID = runID + `-` + runID
	switch surface {
	case "drift":
		if len(args) == 0 {
			i.input("operation", "drift")
		} else if len(args) == 2 && args[0] == "assess-pull-request" && matches(runID, args[1]) {
			i.pullRequest = args[1]
		} else {
			return i, invalid
		}
	case "foundation":
		if len(args) < 2 || (args[1] != "bootstrap" && args[1] != "foundation") {
			return i, invalid
		}
		i.input("operation", args[0])
		i.input("root", args[1])
		switch {
		case args[0] == "plan" && len(args) == 2:
			i.attempt = true
		case args[0] == "apply" && len(args) == 3 && matches(attemptID, args[2]):
			i.planID, i.planPrefix = args[2], "foundation plan "+args[1]+" by @"
			i.input("plan_id", i.planID)
		default:
			return i, invalid
		}
	case "release":
		if len(args) == 0 {
			return i, invalid
		}
		i.input("action", args[0])
		switch {
		case args[0] == "deploy" && (len(args) == 1 || len(args) == 2 && args[1] == "--no-wait"):
			i.noWait = len(args) == 2
		case args[0] == "rollback" && len(args) == 2 && matches(attemptID, args[1]):
			i.input("target_receipt", args[1])
		case args[0] == "recover-first-launch" && len(args) == 2 && matches(runID, args[1]):
			i.input("failed_run_id", args[1])
		case len(args) == 3 && matches(attemptID, args[1]) &&
			(args[0] == "drill-database-isolation" && args[2] == "DRILL authentication" ||
				args[0] == "restore-database-isolation" && args[2] == "RESTORE authentication"):
			i.input("target_receipt", args[1])
			i.input("confirm_isolation", args[2])
		default:
			return i, invalid
		}
	case "recovery":
		if len(args) < 3 || !matches(`[a-z][a-z0-9-]{4,28}[a-z0-9]`, args[1]) || !matches(attemptID, args[2]) {
			return i, invalid
		}
		i.input("operation", args[0])
		i.input("replacement_project_id", args[1])
		i.input("target_receipt", args[2])
		switch {
		case args[0] == "plan-workload" && len(args) == 3:
			i.attempt = true
		case args[0] == "apply-workload" && len(args) == 4 && matches(attemptID, args[3]):
			i.planID, i.planPrefix = args[3], "recovery plan-workload "+args[1]+" by @"
			i.input("plan_id", i.planID)
		case args[0] == "restore-data" && len(args) == 7 &&
			matches(`[0-9]+-[a-z0-9-]{1,63}-[0-9]+`, args[3]) &&
			matches(`[0-9]+-[a-z0-9-]{1,63}-[0-9]+`, args[4]) && args[5] != "" &&
			utf8.RuneCountInString(args[5]) <= 500 && strings.IndexFunc(args[5], unicode.IsControl) < 0 &&
			args[6] == "RESTORE "+args[1]:
			i.attempt = true
			i.input("json_keys_attempt", args[3])
			i.input("authentication_attempt", args[4])
			i.input("lost_write_window", args[5])
			i.input("confirm", args[6])
		case args[0] == "cleanup-project" && len(args) == 4 && args[3] == "DELETE "+args[1]:
			i.input("confirm", args[3])
		default:
			return i, invalid
		}
	default:
		return i, invalid
	}
	return i, nil
}
