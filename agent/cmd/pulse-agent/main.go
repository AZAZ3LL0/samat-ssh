// Command pulse-agent monitors and manages the Linux server it runs on.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/auth"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/config"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/store"
)

const usage = `usage: pulse-agent [--config <path>] <command>

commands:
  pair [--json]        print a one-time pairing code for a new device
  tokens list          list device tokens
  tokens revoke <id>   revoke a device token
`

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := run(ctx, os.Args[1:], os.Stdout)
	stop()
	if err != nil {
		fmt.Fprintln(os.Stderr, "pulse-agent:", err)
		var bad usageError
		if errors.As(err, &bad) {
			fmt.Fprint(os.Stderr, "\n", usage)
		}
		os.Exit(1)
	}
}

// usageError marks a malformed invocation, answered with the usage text.
type usageError string

func (e usageError) Error() string { return string(e) }

func run(ctx context.Context, args []string, out io.Writer) error {
	flags := flag.NewFlagSet("pulse-agent", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	configPath := flags.String("config", config.DefaultPath, "path to config.yaml")
	if err := flags.Parse(args); err != nil {
		return usageError(err.Error())
	}
	command, rest := flags.Arg(0), flags.Args()
	if len(rest) > 0 {
		rest = rest[1:]
	}

	switch command {
	case "pair":
		return withEnv(ctx, *configPath, func(e env) error { return runPair(ctx, e, rest, out) })
	case "tokens":
		return withEnv(ctx, *configPath, func(e env) error { return runTokens(ctx, e, rest, out) })
	case "":
		return usageError("missing command")
	default:
		return usageError(fmt.Sprintf("unknown command %q", command))
	}
}

// env is what every command needs: the config and the credential service.
type env struct {
	cfg  config.Config
	auth *auth.Service
}

func withEnv(ctx context.Context, configPath string, fn func(env) error) error {
	cfg, err := config.Load(configPath)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(cfg.DataDir, 0o700); err != nil {
		return fmt.Errorf("create data dir %s: %w", cfg.DataDir, err)
	}
	st, err := store.Open(ctx, cfg.DBPath())
	if err != nil {
		return err
	}
	defer func() { _ = st.Close() }()
	return fn(env{cfg: cfg, auth: auth.NewService(st, time.Now)})
}

// advertiseHost is the address the app dials: the configured one, else the hostname.
func advertiseHost(cfg config.Config) (string, error) {
	if cfg.Server.AdvertiseHost != "" {
		return cfg.Server.AdvertiseHost, nil
	}
	hostname, err := os.Hostname()
	if err != nil {
		return "", fmt.Errorf("read hostname: %w", err)
	}
	return hostname, nil
}
