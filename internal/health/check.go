package health

import (
	"context"
	"errors"
	"io"
	"net/http"
	"time"
)

// Check verifies one public service's complete dependency contract without retrying.
// A nil transport uses verified HTTPS. Callers injecting a transport own its security.
func Check(ctx context.Context, service, url string, transport http.RoundTripper) error {
	if !validURL(url) || (service != "authentication" && service != "json-keys") {
		return errors.New("invalid public health target")
	}
	client := newClient(transport, 5*time.Second, 15*time.Second)
	defer client.CloseIdleConnections()
	down, err := check(ctx, client, service, url, io.Discard)
	if err != nil {
		return err
	}
	if down {
		return errors.New("service dependency unhealthy")
	}
	return nil
}
