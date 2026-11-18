package contracttest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestFixtures is the gate behind make validate-fixtures: the seed data shared
// by the agent's --fake mode and the app's FakeAgentClient must match the contract.
func TestFixtures(t *testing.T) {
	violations, err := ValidateFixtures(readSpec(t), RepoPath("fixtures"))
	if err != nil {
		t.Fatal(err)
	}
	for _, v := range violations {
		t.Error(v)
	}
}

func TestFixturesRejectsContractViolations(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "host_metrics/missing_cpu.json", `{"ts":"2026-11-15T10:00:00.000Z","memory":{"totalBytes":1,"usedBytes":0,"availableBytes":1}}`)
	write(t, dir, "host_metrics/notes.txt", `not a fixture`)
	write(t, dir, "agent_info/bad_feature.jsonl", `{"agentVersion":"0.1.0","apiVersion":2,"minClientApiVersion":1,"hostname":"a","features":[]}`+"\n"+
		`{"agentVersion":"0.1.0","apiVersion":2,"minClientApiVersion":1,"hostname":"a","features":["telepathy"]}`)
	write(t, dir, "made_up_schema/x.json", `{}`)
	write(t, dir, "loose.json", `{}`)

	violations, err := ValidateFixtures(readSpec(t), dir)
	if err != nil {
		t.Fatal(err)
	}
	report := strings.Join(violations, "\n")
	for _, want := range []string{
		"host_metrics/missing_cpu.json: not a valid HostMetrics",
		"host_metrics/notes.txt: fixtures are .json or .jsonl files",
		"agent_info/bad_feature.jsonl:2: not a valid AgentInfo",
		"made_up_schema: no schema MadeUpSchema in the contract",
		"loose.json: fixtures live in a directory",
	} {
		if !strings.Contains(report, want) {
			t.Errorf("violations miss %q:\n%s", want, report)
		}
	}
	if strings.Contains(report, "bad_feature.jsonl:1") {
		t.Errorf("valid line reported:\n%s", report)
	}
}

func readSpec(t *testing.T) []byte {
	t.Helper()
	spec, err := os.ReadFile(RepoPath("api", "openapi.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	return spec
}

func write(t *testing.T, dir, name, content string) {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}
