package submission

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strconv"
	"strings"

	"cloud.google.com/go/deploy/apiv1/deploypb"
)

const sourceDirectory = "deploy/cloud-deploy/json-keys/"

// sourceArchive reads committed blobs, not working-tree files. The caller must
// authorize the checkout/commit; this check only binds its contents to the request.
func sourceArchive(ctx context.Context, directory, commit string) ([]byte, error) {
	head, err := sourceGit(ctx, directory, "rev-parse", "--verify", "HEAD^{commit}")
	if err != nil || strings.TrimSpace(string(head)) != commit {
		return nil, errors.New("source checkout must be at the exact reviewed request commit")
	}
	var archive bytes.Buffer
	zipped := gzip.NewWriter(&archive)
	writer := tar.NewWriter(zipped)
	for _, name := range []string{"skaffold.yaml", "service.yaml"} {
		path := sourceDirectory + name
		entry, err := sourceGit(ctx, directory, "ls-tree", "-l", commit, "--", path)
		if err != nil {
			return nil, err
		}
		fields := strings.Fields(string(entry))
		if len(fields) != 5 || fields[4] != path {
			return nil, errors.New("source must contain both allowlisted YAML paths")
		}
		if fields[0] != "100644" || fields[1] != "blob" || !commitPattern.MatchString(fields[2]) {
			return nil, errors.New("source must contain both allowlisted non-executable regular YAML files")
		}
		size, err := strconv.Atoi(fields[3])
		if err != nil || size <= 0 || size > 16<<10 {
			return nil, errors.New("source file must be nonempty and at most 16 KiB")
		}
		// The immutable blob's size is checked before reading. cat-file does not run
		// checkout filters or text conversions, and replacement objects are disabled.
		data, err := sourceGit(ctx, directory, "cat-file", "blob", fields[2])
		if err != nil || len(data) != size {
			return nil, errors.New("cannot read the exact reviewed source blob")
		}
		if err := writer.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(size), Format: tar.FormatUSTAR}); err != nil {
			return nil, fmt.Errorf("encode source header: %w", err)
		}
		if _, err := writer.Write(data); err != nil {
			return nil, fmt.Errorf("encode source file: %w", err)
		}
	}
	if err := writer.Close(); err != nil {
		return nil, fmt.Errorf("finish source archive: %w", err)
	}
	if err := zipped.Close(); err != nil {
		return nil, fmt.Errorf("finish source compression: %w", err)
	}
	return archive.Bytes(), nil
}

// Read-only plumbing deliberately avoids archive attributes, filters and hooks.
func sourceGit(ctx context.Context, directory string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, "git", append([]string{"--no-replace-objects", "--no-lazy-fetch", "-C", directory}, args...)...)
	data, err := command.Output()
	if err != nil {
		return nil, errors.New("cannot read reviewed source from the selected Git checkout")
	}
	return data, nil
}

func (scope scope) sourceName(request *deploypb.CreateReleaseRequest) string {
	return scope.prefix() + "sources/" + request.Release.Annotations["source-commit"] + ".tar.gz"
}

// Publication is an immutable artifact operation, unlike release/migration dispatch:
// matching bytes establish success even if the create-only upload acknowledgement was lost.
func (client cloud) publishSource(ctx context.Context, request *deploypb.CreateReleaseRequest, archive []byte, output io.Writer) error {
	_ = client.upload(ctx, client.scope.sourceName(request), archive, "application/gzip") // Read-back below establishes the outcome.
	if err := client.verifySource(ctx, request, archive); err != nil {
		return err
	}
	_, err := fmt.Fprintf(output, "Source: %s\nExact committed archive verified. No release submitted.\n", request.Release.SkaffoldConfigUri)
	return err
}

func (client cloud) verifySource(ctx context.Context, request *deploypb.CreateReleaseRequest, archive []byte) error {
	stored, err := client.read(ctx, client.scope.sourceName(request))
	if err != nil || !bytes.Equal(stored, archive) {
		return errors.New("source archive missing, unreadable or different from the selected commit; no release dispatched")
	}
	return nil
}
