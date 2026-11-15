// Package config loads the agent's config.yaml.
package config

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

// DefaultPath is where the installed agent reads its config.
const DefaultPath = "/etc/pulse-agent/config.yaml"

// Config is the content of config.yaml.
type Config struct {
	Server  Server `yaml:"server"`
	DataDir string `yaml:"data_dir"`
}

// Server configures the API listener.
type Server struct {
	Host string `yaml:"host"`
	Port int    `yaml:"port"`
	// AdvertiseHost is the address the app dials, printed in the pairing link.
	// Empty means the machine hostname.
	AdvertiseHost string `yaml:"advertise_host"`
}

// Default returns the config used for keys absent from the file.
func Default() Config {
	return Config{
		Server:  Server{Host: "0.0.0.0", Port: 7443},
		DataDir: "/var/lib/pulse-agent",
	}
}

// Load reads the config at path on top of the defaults.
func Load(path string) (Config, error) {
	file, err := os.Open(path) //nolint:gosec // the path comes from the operator's --config flag
	if err != nil {
		return Config{}, fmt.Errorf("open config: %w", err)
	}
	defer func() { _ = file.Close() }()

	cfg := Default()
	decoder := yaml.NewDecoder(file)
	// A typo in a key must fail loudly instead of silently keeping the default.
	decoder.KnownFields(true)
	if err := decoder.Decode(&cfg); err != nil && !errors.Is(err, io.EOF) {
		return Config{}, fmt.Errorf("parse config %s: %w", path, err)
	}
	if err := cfg.validate(); err != nil {
		return Config{}, fmt.Errorf("config %s: %w", path, err)
	}
	return cfg, nil
}

func (c Config) validate() error {
	if c.Server.Port < 1 || c.Server.Port > 65535 {
		return fmt.Errorf("server.port %d is out of range 1..65535", c.Server.Port)
	}
	if c.Server.Host == "" {
		return errors.New("server.host is empty")
	}
	if !filepath.IsAbs(c.DataDir) {
		return fmt.Errorf("data_dir %q is not an absolute path", c.DataDir)
	}
	return nil
}

// DBPath is the SQLite database file.
func (c Config) DBPath() string {
	return filepath.Join(c.DataDir, "pulse.db")
}

// TLSDir holds the generated certificate and key.
func (c Config) TLSDir() string {
	return filepath.Join(c.DataDir, "tls")
}
