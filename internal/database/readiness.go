package database

import (
	"context"
	"errors"
	"os/exec"
	"sort"
	"strings"
	"time"
)

func validStatus(status string) bool {
	return matches(`(starting|healthy|idle|failed):(none|invalid|[a-f0-9]{40}):[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}`, status)
}

func (h host) instance(ctx context.Context) (string, error) {
	name, err := h.compute(ctx, "instance-groups", "managed", "list-instances", h.group(), "--format=value(instance.basename())")
	if err != nil || !matches(h.group()+`-[a-z0-9]+`, name) {
		return "", failure{70, "expected exactly one generated database host"}
	}
	return name, nil
}

func (h host) status(ctx context.Context, instance string) (string, error) {
	status, err := h.compute(ctx, "instances", "get-guest-attributes", instance, "--query-path=agora/database-release", "--format=value(value)")
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) && strings.Contains(string(exit.Stderr), "Guest Attribute") && matches(`(?s).*(?i:not found|404).*`, string(exit.Stderr)) {
			return "absent", nil
		}
		return "", failure{70, "database readiness could not be read"}
	}
	if !validStatus(status) {
		return "", failure{70, "malformed database readiness status"}
	}
	return status, nil
}

func (h host) current(ctx context.Context) (string, error) {
	instance, err := h.instance(ctx)
	if err != nil {
		return "", err
	}
	return h.status(ctx, instance)
}

func (h host) wait(ctx context.Context, revision, previous string) error {
	instance, err := h.instance(ctx)
	if err != nil {
		return err
	}
	prefix := "healthy:" + revision + ":"
	if revision == "none" {
		prefix = "idle:none:"
	}
	for attempt := range 86 {
		status, err := h.status(ctx, instance)
		if err != nil {
			return err
		}
		if status != previous {
			if strings.HasPrefix(status, "failed:") {
				return failure{70, "database host reported failed startup"}
			}
			if strings.HasPrefix(status, prefix) {
				return nil
			}
		}
		if attempt < 85 {
			// Guest attribute reads are limited to ten queries per minute.
			timer := time.NewTimer(7 * time.Second)
			select {
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			case <-timer.C:
			}
		}
	}
	return failure{70, "database readiness timed out without the expected new boot"}
}

func (h host) restart(ctx context.Context, metadata map[string]string) error {
	if err := h.checkDisk(ctx); err != nil {
		return err
	}
	previous, err := h.current(ctx)
	if err != nil {
		return err
	}
	values := make([]string, 0, len(metadata))
	for key, value := range metadata {
		values = append(values, key+"="+value)
	}
	sort.Strings(values)
	// OPPORTUNISTIC metadata needs an explicit update capped at RESTART.
	for _, step := range [][]string{
		{"all-instances-config", "update", h.group(), "--metadata=" + strings.Join(values, ","), "--quiet"},
		{"update-instances", h.group(), "--all-instances", "--minimal-action=restart", "--most-disruptive-allowed-action=restart", "--quiet"},
		{"wait-until", h.group(), "--stable", "--timeout=600", "--quiet"},
	} {
		if _, err = h.compute(ctx, append([]string{"instance-groups", "managed"}, step...)...); err != nil {
			return failure{70, "database " + step[0] + " failed; reconcile the selected host before retrying"}
		}
	}
	revision := metadata[revisionKey]
	if revision == "" {
		revision = "none"
	}
	return h.wait(ctx, revision, previous)
}
