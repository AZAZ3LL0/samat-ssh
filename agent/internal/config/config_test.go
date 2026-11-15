package config

import (
	"os"
	"path/filepath"
	"testing"
)

func write(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return path
}

func TestLoadAppliesDefaults(t *testing.T) {
	for name, content := range map[string]string{
		"empty file":  "",
		"partial key": "server:\n  advertise_host: vps.example.com\n",
	} {
		t.Run(name, func(t *testing.T) {
			cfg, err := Load(write(t, content))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			if cfg.Server.Port != 7443 {
				t.Errorf("port = %d, want 7443", cfg.Server.Port)
			}
			if cfg.DataDir != "/var/lib/pulse-agent" {
				t.Errorf("data_dir = %q, want /var/lib/pulse-agent", cfg.DataDir)
			}
			if got, want := cfg.DBPath(), "/var/lib/pulse-agent/pulse.db"; got != want {
				t.Errorf("db path = %q, want %q", got, want)
			}
			if got, want := cfg.TLSDir(), "/var/lib/pulse-agent/tls"; got != want {
				t.Errorf("tls dir = %q, want %q", got, want)
			}
		})
	}
}

func TestLoadOverridesDefaults(t *testing.T) {
	cfg, err := Load(write(t, "server:\n  host: 127.0.0.1\n  port: 8443\ndata_dir: /tmp/pulse\n"))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.Server.Host != "127.0.0.1" || cfg.Server.Port != 8443 || cfg.DataDir != "/tmp/pulse" {
		t.Errorf("config = %+v", cfg)
	}
}

func TestLoadRejectsInvalidConfig(t *testing.T) {
	for name, content := range map[string]string{
		"unknown key":       "sever:\n  port: 1\n",
		"port out of range": "server:\n  port: 70000\n",
		"relative data dir": "data_dir: var/pulse\n",
		"malformed yaml":    "server: [",
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := Load(write(t, content)); err == nil {
				t.Fatal("load succeeded, want an error")
			}
		})
	}
}

func TestLoadFailsOnMissingFile(t *testing.T) {
	if _, err := Load(filepath.Join(t.TempDir(), "absent.yaml")); err == nil {
		t.Fatal("load succeeded, want an error")
	}
}

func TestExampleConfigMatchesDefaults(t *testing.T) {
	cfg, err := Load("../../config.example.yaml")
	if err != nil {
		t.Fatalf("load example: %v", err)
	}
	if cfg != Default() {
		t.Errorf("example config = %+v, want defaults %+v", cfg, Default())
	}
}
