package operator

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

func ensureKey(ctx context.Context, path string, execute func(context.Context, io.Writer, string, ...string) error, output io.Writer) error {
	private, privateErr := os.Stat(path)
	public, publicErr := os.Stat(path + ".pub")
	if errors.Is(privateErr, os.ErrNotExist) && errors.Is(publicErr, os.ErrNotExist) {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return fmt.Errorf("create SSH key directory: %w", err)
		}
		if err := execute(ctx, output, "ssh-keygen", "-t", "ed25519", "-a", "64", "-C", "a-novel-database-operator", "-f", path); err != nil {
			return fmt.Errorf("create SSH key: %w", err)
		}
		private, privateErr = os.Stat(path)
		public, publicErr = os.Stat(path + ".pub")
	}
	if privateErr != nil || publicErr != nil || !private.Mode().IsRegular() || !public.Mode().IsRegular() {
		return errors.New("SSH private and public key files must both exist")
	}
	if private.Size() == 0 || public.Size() == 0 {
		return errors.New("SSH key pair is empty")
	}
	data, err := os.ReadFile(path + ".pub")
	if err != nil {
		return fmt.Errorf("read public SSH key: %w", err)
	}
	line, _, _ := strings.Cut(string(data), "\n")
	fields := strings.Fields(line)
	if len(fields) == 0 || fields[0] != "ssh-ed25519" && !strings.HasPrefix(fields[0], "ecdsa-sha2-") {
		return errors.New("use an Ed25519 or ECDSA SSH key")
	}
	if _, err := fmt.Fprintln(output, "PASS local SSH key pair"); err != nil {
		return fmt.Errorf("write SSH key verification: %w", err)
	}
	return nil
}
