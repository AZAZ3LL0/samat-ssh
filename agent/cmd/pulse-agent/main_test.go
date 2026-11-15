package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/auth"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/config"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/store"
)

// writeConfig returns the path of a config pointing at a fresh data dir.
func writeConfig(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	content := fmt.Sprintf("server:\n  port: 8443\n  advertise_host: vps.example.com\ndata_dir: %s\n", filepath.Join(dir, "data"))
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return path
}

func runCLI(t *testing.T, configPath string, args ...string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	err := run(context.Background(), append([]string{"--config", configPath}, args...), &out)
	return out.String(), err
}

func pairJSON(t *testing.T, configPath string) pairing {
	t.Helper()
	out, err := runCLI(t, configPath, "pair", "--json")
	if err != nil {
		t.Fatalf("pair --json: %v", err)
	}
	var p pairing
	if err := json.Unmarshal([]byte(out), &p); err != nil {
		t.Fatalf("pair --json printed %q: %v", out, err)
	}
	return p
}

// exchange redeems a pairing code the way POST /v1/pair will.
func exchange(t *testing.T, configPath, code, device string) (token, tokenID string, err error) {
	t.Helper()
	cfg, err := config.Load(configPath)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	st, err := store.Open(context.Background(), cfg.DBPath())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer func() { _ = st.Close() }()
	return auth.NewService(st, time.Now).Pair(context.Background(), code, device)
}

func TestPairJSONDescribesAgentAndIssuesRedeemableCode(t *testing.T) {
	configPath := writeConfig(t)
	p := pairJSON(t, configPath)

	if p.Host != "vps.example.com" || p.Port != 8443 {
		t.Errorf("host:port = %s:%d, want vps.example.com:8443", p.Host, p.Port)
	}
	link, err := url.Parse(p.URL)
	if err != nil {
		t.Fatalf("parse url %q: %v", p.URL, err)
	}
	if link.Scheme != "pulse" || link.Host != "pair" {
		t.Errorf("url = %q, want pulse://pair?...", p.URL)
	}
	query := link.Query()
	want := map[string]string{"h": p.Host, "p": strconv.Itoa(p.Port), "fp": p.FP, "c": p.Code}
	for key, value := range want {
		if query.Get(key) != value {
			t.Errorf("url param %s = %q, want %q", key, query.Get(key), value)
		}
	}
	expiresAt, err := time.Parse(time.RFC3339, p.ExpiresAt)
	if err != nil {
		t.Fatalf("expiresAt %q is not RFC 3339: %v", p.ExpiresAt, err)
	}
	if left := time.Until(expiresAt); left < 9*time.Minute || left > 10*time.Minute {
		t.Errorf("code expires in %s, want 10 minutes", left)
	}
	if _, _, err := exchange(t, configPath, p.Code, "iPhone"); err != nil {
		t.Errorf("printed code was not redeemable: %v", err)
	}
}

func TestPairKeepsFingerprintAndRotatesCode(t *testing.T) {
	configPath := writeConfig(t)
	first, second := pairJSON(t, configPath), pairJSON(t, configPath)
	if first.FP != second.FP {
		t.Errorf("fingerprint changed between runs: %s != %s", first.FP, second.FP)
	}
	if first.Code == second.Code {
		t.Error("two runs printed the same code")
	}
}

func TestPairPrintsLinkForHumans(t *testing.T) {
	out, err := runCLI(t, writeConfig(t), "pair")
	if err != nil {
		t.Fatalf("pair: %v", err)
	}
	if !strings.Contains(out, "pulse://pair?h=vps.example.com&p=8443&fp=") {
		t.Errorf("output has no pairing link:\n%s", out)
	}
}

func TestTokensListAndRevoke(t *testing.T) {
	configPath := writeConfig(t)
	_, phoneID, err := exchange(t, configPath, pairJSON(t, configPath).Code, "iPhone")
	if err != nil {
		t.Fatalf("pair iPhone: %v", err)
	}
	padToken, padID, err := exchange(t, configPath, pairJSON(t, configPath).Code, "iPad")
	if err != nil {
		t.Fatalf("pair iPad: %v", err)
	}

	out, err := runCLI(t, configPath, "tokens", "revoke", phoneID)
	if err != nil {
		t.Fatalf("tokens revoke: %v", err)
	}
	if !strings.Contains(out, phoneID) {
		t.Errorf("revoke output %q does not name the token", out)
	}

	out, err = runCLI(t, configPath, "tokens", "list")
	if err != nil {
		t.Fatalf("tokens list: %v", err)
	}
	for id, wantStatus := range map[string]string{phoneID: "revoked", padID: "active"} {
		line := lineContaining(out, id)
		if line == "" {
			t.Fatalf("token %s is missing from the list:\n%s", id, out)
		}
		if !strings.Contains(line, wantStatus) {
			t.Errorf("line %q, want status %s", line, wantStatus)
		}
	}
	if strings.Contains(out, padToken) {
		t.Error("tokens list printed a token secret")
	}

	if _, err := runCLI(t, configPath, "tokens", "revoke", phoneID); err == nil {
		t.Error("revoking an already revoked token succeeded")
	}
	if _, err := runCLI(t, configPath, "tokens", "revoke", "missing"); err == nil {
		t.Error("revoking an unknown token succeeded")
	}
}

func TestRunRejectsBadInvocation(t *testing.T) {
	configPath := writeConfig(t)
	for name, args := range map[string][]string{
		"no command":       {},
		"unknown command":  {"frobnicate"},
		"tokens no action": {"tokens"},
		"revoke no id":     {"tokens", "revoke"},
		"unknown flag":     {"pair", "--yaml"},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := runCLI(t, configPath, args...); err == nil {
				t.Fatal("run succeeded, want an error")
			}
		})
	}
	if _, err := runCLI(t, filepath.Join(t.TempDir(), "absent.yaml"), "tokens", "list"); err == nil {
		t.Error("run with a missing config succeeded")
	}
}

func lineContaining(text, needle string) string {
	for line := range strings.SplitSeq(text, "\n") {
		if strings.Contains(line, needle) {
			return line
		}
	}
	return ""
}
