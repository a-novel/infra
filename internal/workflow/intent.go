package workflow

import (
	"errors"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

const usage = `usage: go run ./cmd/infra
  drift
  drift assess-pull-request <pull-request-number>
  drift inspect-operation <json-keys|authentication> [guard-generation]
  foundation plan <bootstrap|foundation>
  foundation apply <bootstrap|foundation> <plan-id>
  foundation plan <service-foundation|service-release> <json-keys|authentication>
  foundation apply <service-foundation|service-release> <json-keys|authentication> <plan-id>
  foundation promote-images service-release <json-keys|authentication>
  foundation finish-operation <service> <guard-generation> 'FINISH <service> <guard-generation>'
  foundation recover-legacy <guard-generation> 'RECOVER LEGACY <guard-generation>'
  release drill-database-isolation <receipt-id> 'DRILL authentication'
  release restore-database-isolation <receipt-id> 'RESTORE authentication'

  recovery plan-native <registered-recovery-project>
  recovery apply-native <registered-recovery-project> <plan-id>
  recovery restore-native <registered-recovery-project> <preparation-generation> '<RESTORE-FILES|RESTORE-SQL> <project> <preparation-generation>'
  recovery cleanup-native <registered-recovery-project> 'DELETE <project>'`

type intent struct {
	workflow, planID, planPrefix, pullRequest string
	inputs                                    []string
	attempt, observation                      bool
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
			break
		}
		switch args[0] {
		case "assess-pull-request":
			if len(args) != 2 || !matches(runID, args[1]) {
				return i, invalid
			}
			i.pullRequest = args[1]
		case "inspect-operation":
			if len(args) < 2 || len(args) > 3 || !slices.Contains([]string{"json-keys", "authentication"}, args[1]) {
				return i, invalid
			}
			i.observation = true
			i.input("operation", "inspect-operation")
			i.input("service", args[1])
			if len(args) == 3 {
				generation, err := strconv.ParseInt(args[2], 10, 64)
				if err != nil || generation <= 0 || strconv.FormatInt(generation, 10) != args[2] {
					return i, invalid
				}
				i.input("guard_generation", args[2])
			}
		default:
			return i, invalid
		}
	case "foundation":
		if len(args) > 0 && args[0] == "recover-legacy" {
			if len(args) != 3 {
				return i, invalid
			}
			generation, err := strconv.ParseInt(args[1], 10, 64)
			if err != nil || generation <= 0 || strconv.FormatInt(generation, 10) != args[1] || args[2] != "RECOVER LEGACY "+args[1] {
				return i, invalid
			}
			i.input("operation", args[0])
			i.input("root", "foundation")
			i.input("service", "none")
			i.input("guard_generation", args[1])
			i.input("confirm", args[2])
			break
		}
		if len(args) > 0 && args[0] == "finish-operation" {
			if len(args) != 4 || !slices.Contains([]string{"json-keys", "authentication"}, args[1]) {
				return i, invalid
			}
			generation, err := strconv.ParseInt(args[2], 10, 64)
			if err != nil || generation <= 0 || strconv.FormatInt(generation, 10) != args[2] || args[3] != "FINISH "+args[1]+" "+args[2] {
				return i, invalid
			}
			i.input("operation", args[0])
			i.input("root", "none")
			i.input("service", args[1])
			i.input("guard_generation", args[2])
			i.input("confirm", args[3])
			break
		}
		if len(args) < 2 || !slices.Contains([]string{"bootstrap", "foundation", "service-foundation", "service-release"}, args[1]) {
			return i, invalid
		}
		i.input("operation", args[0])
		i.input("root", args[1])
		scope := args[1]
		if strings.HasPrefix(args[1], "service-") {
			if len(args) < 3 || !slices.Contains([]string{"json-keys", "authentication"}, args[2]) {
				return i, invalid
			}
			i.input("service", args[2])
			scope += "/" + args[2]
			args = slices.Concat(args[:2], args[3:])
		}
		switch {
		case args[0] == "plan" && len(args) == 2:
			i.attempt = true
		case args[0] == "promote-images" && args[1] == "service-release" && len(args) == 2:
			// Image publication has no saved plan and returns only its workflow run ID.
		case args[0] == "apply" && len(args) == 3 && matches(attemptID, args[2]):
			i.planID, i.planPrefix = args[2], "foundation plan "+scope+" by @"
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
		case len(args) == 3 && matches(attemptID, args[1]) &&
			(args[0] == "drill-database-isolation" && args[2] == "DRILL authentication" ||
				args[0] == "restore-database-isolation" && args[2] == "RESTORE authentication"):
			i.input("target_receipt", args[1])
			i.input("confirm_isolation", args[2])
		default:
			return i, invalid
		}
	case "recovery":
		if len(args) >= 2 && slices.Contains([]string{"plan-native", "apply-native", "restore-native", "cleanup-native"}, args[0]) {
			if !matches(`a-novel-recovery-[a-z0-9-]{1,13}[a-z0-9]`, args[1]) {
				return i, invalid
			}
			i.input("operation", args[0])
			i.input("replacement_project_id", args[1])
			switch {
			case args[0] == "cleanup-native" && len(args) == 3 && args[2] == "DELETE "+args[1]:
				i.input("confirm", args[2])
			case args[0] == "plan-native" && len(args) == 2:
				i.attempt = true
			case args[0] == "apply-native" && len(args) == 3 && matches(attemptID, args[2]):
				i.planID, i.planPrefix = args[2], "recovery plan-native "+args[1]+" by @"
				i.input("plan_id", i.planID)
			case args[0] == "restore-native" && len(args) == 4:
				generation, err := strconv.ParseInt(args[2], 10, 64)
				if err != nil || generation <= 0 || strconv.FormatInt(generation, 10) != args[2] ||
					!slices.Contains([]string{"RESTORE-FILES " + args[1] + " " + args[2], "RESTORE-SQL " + args[1] + " " + args[2]}, args[3]) {
					return i, invalid
				}
				i.input("preparation_generation", args[2])
				i.input("confirm", args[3])
			default:
				return i, invalid
			}
			break
		}
		return i, invalid
	default:
		return i, invalid
	}
	return i, nil
}
