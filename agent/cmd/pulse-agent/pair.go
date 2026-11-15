package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/url"
	"strconv"
	"time"

	"github.com/mdp/qrterminal/v3"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/auth"
)

// timeFormat is the API-wide timestamp format: RFC 3339, UTC, milliseconds.
const timeFormat = "2006-01-02T15:04:05.000Z"

// pairing is the `pair --json` output, consumed by the app's SSH install flow.
type pairing struct {
	Host      string `json:"host"`
	Port      int    `json:"port"`
	FP        string `json:"fp"`
	Code      string `json:"code"`
	ExpiresAt string `json:"expiresAt"`
	URL       string `json:"url"`
}

func runPair(ctx context.Context, e env, args []string, out io.Writer) error {
	flags := flag.NewFlagSet("pair", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	asJSON := flags.Bool("json", false, "print machine-readable JSON instead of a QR code")
	if err := flags.Parse(args); err != nil {
		return usageError("pair: " + err.Error())
	}

	host, err := advertiseHost(e.cfg)
	if err != nil {
		return err
	}
	// Pairing may run before the agent's first start, so it creates the
	// certificate the agent will then serve.
	cert, err := auth.LoadOrCreateCert(e.cfg.TLSDir(), host, time.Now())
	if err != nil {
		return err
	}
	fp, err := auth.Fingerprint(cert)
	if err != nil {
		return err
	}
	code, expiresAt, err := e.auth.NewPairingCode(ctx)
	if err != nil {
		return err
	}

	p := pairing{
		Host:      host,
		Port:      e.cfg.Server.Port,
		FP:        fp,
		Code:      code,
		ExpiresAt: expiresAt.UTC().Format(timeFormat),
		URL: "pulse://pair?h=" + url.QueryEscape(host) + "&p=" + strconv.Itoa(e.cfg.Server.Port) +
			"&fp=" + url.QueryEscape(fp) + "&c=" + url.QueryEscape(code),
	}
	if *asJSON {
		return json.NewEncoder(out).Encode(p)
	}
	qrterminal.GenerateHalfBlock(p.URL, qrterminal.L, out)
	_, err = fmt.Fprintf(out, "\n%s\n\ncode:        %s (valid until %s)\nfingerprint: %s\n", p.URL, p.Code, p.ExpiresAt, p.FP)
	return err
}
