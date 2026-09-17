package health

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"
)

// Run checks a candidate URL or the deployed service selected by private foundation
// configuration. execute must keep child diagnostics private. A nil transport uses
// verified HTTPS; callers supplying one retain responsibility for connection security.
// Exit codes are 64 for usage, 65 for configuration, and 70 for failed health checks.
func Run(ctx context.Context, args []string, execute func(context.Context, io.Writer, string, ...string) error, transport http.RoundTripper, stdout, stderr io.Writer) int {
	stop := func(code int, message string) int {
		_, _ = fmt.Fprintln(stderr, message) // Best effort if the diagnostic stream has closed.
		return code
	}
	if len(args) != 2 || (args[0] != "candidate" && args[0] != "deployed") {
		return stop(64, "Usage: infra check-health candidate <url> | deployed <foundation-config>")
	}
	url, attempts, connectTimeout, timeout := args[1], 3, 5*time.Second, 15*time.Second
	if args[0] == "deployed" {
		attempts, connectTimeout, timeout = 1, 10*time.Second, 30*time.Second
		var config struct {
			Project string `json:"workload_project_id"`
			Region  string `json:"region"`
		}
		data, err := os.ReadFile(args[1])
		if err != nil || json.Unmarshal(data, &config) != nil ||
			!regexp.MustCompile(`^[a-z][a-z0-9-]{4,28}[a-z0-9]$`).MatchString(config.Project) ||
			!regexp.MustCompile(`^[a-z]+-[a-z]+[0-9]+$`).MatchString(config.Region) {
			return stop(65, "The private foundation configuration has invalid service coordinates.")
		}
		var output bytes.Buffer
		if err = execute(ctx, &output, "gcloud", "run", "services", "describe", "agora-authentication-rest",
			"--project="+config.Project, "--region="+config.Region, "--format=value(status.url)", "--quiet"); err != nil {
			return stop(70, "The Authentication service URL could not be resolved safely.")
		}
		url = strings.TrimRight(output.String(), "\r\n")
	}
	if !regexp.MustCompile(`^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.run\.app$`).MatchString(url) {
		return stop(70, "The Authentication service URL could not be resolved safely.")
	}
	if transport == nil {
		connection := http.DefaultTransport.(*http.Transport).Clone()
		connection.DialContext = (&net.Dialer{Timeout: connectTimeout}).DialContext
		connection.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
		connection.DisableCompression = true
		transport = connection
		defer connection.CloseIdleConnections()
	}
	client := &http.Client{
		Transport: transport, Timeout: timeout,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	for attempt := 1; attempt <= attempts; attempt++ {
		down, err := check(ctx, client, url, stderr)
		if err != nil {
			return stop(70, err.Error())
		}
		if !down {
			if _, err = fmt.Fprintln(stdout, "Authentication and all declared dependencies are healthy."); err != nil {
				return stop(70, "Cannot report Authentication health.")
			}
			return 0
		}
		if attempt < attempts {
			_, _ = fmt.Fprintln(stderr, "Authentication dependency down; retrying the same candidate in five seconds.") // Fixed diagnostic only.
			select {
			case <-ctx.Done():
				return stop(70, "Authentication health check canceled.")
			case <-time.After(5 * time.Second):
			}
		}
	}
	return stop(70, "Authentication or one of its declared dependencies is unhealthy.")
}

// check permits retries only for the validated dependency-down contract.
func check(ctx context.Context, client *http.Client, url string, stderr io.Writer) (bool, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url+"/v2/healthcheck", nil)
	if err != nil {
		return false, errors.New("authentication health request is invalid")
	}
	request.Header.Set("Accept", "application/json")
	response, err := client.Do(request)
	if err != nil {
		return false, errors.New("authentication HTTPS request failed or exceeded its limits")
	}
	defer func() { _ = response.Body.Close() }() // No response data is used after the bounded read.
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusServiceUnavailable {
		return false, fmt.Errorf("authentication endpoint returned HTTP %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 4097))
	if err != nil || len(data) > 4096 {
		return false, errors.New("authentication health response failed or exceeded its limits")
	}
	var dependencies map[string]map[string]string
	components := []string{"api:jsonKeys", "client:postgres", "client:smtp"}
	if json.Unmarshal(data, &dependencies) != nil || len(dependencies) != len(components) {
		return false, errors.New("authentication returned an unexpected health response schema")
	}
	down := false
	for _, component := range components {
		dependency := dependencies[component]
		if len(dependency) != 1 || (dependency["status"] != "up" && dependency["status"] != "down") {
			return false, errors.New("authentication returned an unexpected health response schema")
		}
		down = down || dependency["status"] == "down"
	}
	if !down && response.StatusCode != http.StatusOK {
		return false, errors.New("authentication endpoint returned HTTP 503 with healthy dependencies")
	}
	if down {
		for _, component := range components {
			_, _ = fmt.Fprintf(stderr, "Authentication health: %s=%s\n", component, dependencies[component]["status"]) // Validated fixed names and enums only.
		}
	}
	return down, nil
}
