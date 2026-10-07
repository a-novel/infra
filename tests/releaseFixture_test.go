package tests_test

import (
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

type releaseFixture struct {
	*sandbox
	receiptFile string
	receipt     object
}

func compiledFixture(t *testing.T) *releaseFixture {
	t.Helper()
	f := &releaseFixture{sandbox: setup(t)}
	f.receipt = readJSON(t, filepath.Join(f.root, "tests/fixtures/historical-receipt.json"))
	f.receiptFile = filepath.Join(f.dir, "receipt.json")
	writeJSON(t, f.receiptFile, f.receipt)
	return f
}

type invocation struct {
	Name   string
	Args   []string
	Output string `json:",omitempty"`
	Code   int    `json:",omitempty"`
}

func (f *sandbox) expect(t *testing.T, calls []invocation) {
	t.Helper()
	f.env["INFRA_TEST_SEQUENCE"] = filepath.Join(f.dir, "expected.json")
	writeJSON(t, f.env["INFRA_TEST_SEQUENCE"], calls)
}

func jsonText(t *testing.T, value any) string {
	t.Helper()
	data, err := json.Marshal(value)
	require.NoError(t, err)
	return string(data)
}
