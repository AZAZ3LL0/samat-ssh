//go:build integration

// Package integration tests the API of an agent running in a Docker container.
// Run it with `make agent-it`; it needs a Docker daemon.
package integration

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
)

const (
	image      = "pulse-agent:integration"
	agentPath  = "/usr/local/bin/pulse-agent"
	startupFor = 30 * time.Second
)

// agent is the container under test.
var agent struct {
	id   string
	addr string // host:port published on the loopback interface
}

func TestMain(m *testing.M) {
	code, err := runSuite(m)
	if err != nil {
		fmt.Fprintln(os.Stderr, "integration:", err)
		code = 1
	}
	os.Exit(code)
}

func runSuite(m *testing.M) (int, error) {
	if _, err := docker("build", "--tag", image, ".."); err != nil {
		return 0, err
	}
	id, err := docker("run", "--detach", "--rm", "--publish", "127.0.0.1::7443", image)
	if err != nil {
		return 0, err
	}
	agent.id = id
	defer func() {
		if logs, err := docker("logs", agent.id); err == nil {
			fmt.Fprintf(os.Stderr, "--- agent log ---\n%s\n", logs)
		}
		_, _ = docker("rm", "--force", agent.id)
	}()

	agent.addr, err = docker("port", agent.id, "7443/tcp")
	if err != nil {
		return 0, err
	}
	if err := waitUntilUp(); err != nil {
		return 0, err
	}
	return m.Run(), nil
}

func docker(args ...string) (string, error) {
	var stdout, stderr bytes.Buffer
	cmd := exec.Command("docker", args...)
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("docker %s: %w\n%s", strings.Join(args, " "), err, stderr.String())
	}
	return strings.TrimSpace(stdout.String()), nil
}

func waitUntilUp() error {
	client := &http.Client{
		Timeout: 2 * time.Second,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{
			InsecureSkipVerify: true, //nolint:gosec // readiness probe only; the tests pin the key
		}},
	}
	deadline := time.Now().Add(startupFor)
	for {
		response, err := client.Get("https://" + agent.addr + "/v1/info")
		if err == nil {
			_ = response.Body.Close()
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("agent did not answer within %s: %w", startupFor, err)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// pairing is the output of `pulse-agent pair --json`.
type pairing struct {
	Port int    `json:"port"`
	FP   string `json:"fp"`
	Code string `json:"code"`
}

// pairCLI asks the agent in the container for a pairing code, the way the
// app's SSH install flow does.
func pairCLI(t *testing.T) pairing {
	t.Helper()
	out, err := docker("exec", agent.id, agentPath, "--fake", "pair", "--json")
	if err != nil {
		t.Fatalf("pair: %v", err)
	}
	var p pairing
	if err := json.Unmarshal([]byte(out), &p); err != nil {
		t.Fatalf("pair --json printed %q: %v", out, err)
	}
	return p
}

// pinned returns a client that, like the app, trusts only the key whose SPKI
// hash equals the fingerprint.
func pinned(fingerprint string) *http.Client {
	return &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{
			InsecureSkipVerify: true, //nolint:gosec // replaced by the pin check below
			VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
				leaf, err := x509.ParseCertificate(rawCerts[0])
				if err != nil {
					return err
				}
				sum := sha256.Sum256(leaf.RawSubjectPublicKeyInfo)
				if base64.RawURLEncoding.EncodeToString(sum[:]) != fingerprint {
					return errors.New("pin mismatch")
				}
				return nil
			},
		}},
	}
}

func decodeBody(t *testing.T, response *http.Response, status int, into any) {
	t.Helper()
	defer func() { _ = response.Body.Close() }()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	if response.StatusCode != status {
		t.Fatalf("status = %d, want %d (body %s)", response.StatusCode, status, body)
	}
	if response.Header.Get("X-Request-Id") == "" {
		t.Error("response has no X-Request-Id")
	}
	if err := json.Unmarshal(body, into); err != nil {
		t.Fatalf("decode %q: %v", body, err)
	}
}

// device pairs a new device and returns its client and token.
func device(t *testing.T) (client *http.Client, token, tokenID string) {
	t.Helper()
	p := pairCLI(t)
	client = pinned(p.FP)
	response, err := client.Post("https://"+agent.addr+"/v1/pair", "application/json",
		strings.NewReader(`{"code":"`+p.Code+`","deviceName":"integration"}`))
	if err != nil {
		t.Fatalf("POST /v1/pair: %v", err)
	}
	var paired gen.PairResponse
	decodeBody(t, response, http.StatusOK, &paired)
	return client, paired.Token, paired.TokenId
}

func dial(ctx context.Context, client *http.Client, token string) (*websocket.Conn, *http.Response, error) {
	header := http.Header{}
	if token != "" {
		header.Set("Authorization", "Bearer "+token)
	}
	return websocket.Dial(ctx, "wss://"+agent.addr+"/v1/ws", &websocket.DialOptions{HTTPClient: client, HTTPHeader: header})
}

type message struct {
	Type    gen.WsMessageType `json:"type"`
	Topic   *string           `json:"topic"`
	Seq     *int64            `json:"seq"`
	Payload json.RawMessage   `json:"payload"`
}

func readMessage(ctx context.Context, t *testing.T, socket *websocket.Conn) message {
	t.Helper()
	_, data, err := socket.Read(ctx)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var msg message
	if err := json.Unmarshal(data, &msg); err != nil {
		t.Fatalf("agent sent %q: %v", data, err)
	}
	return msg
}

func TestInfoAnswersOverPinnedTLS(t *testing.T) {
	p := pairCLI(t)
	response, err := pinned(p.FP).Get("https://" + agent.addr + "/v1/info")
	if err != nil {
		t.Fatalf("GET /v1/info with the fingerprint printed by `pair`: %v", err)
	}
	var info gen.AgentInfo
	decodeBody(t, response, http.StatusOK, &info)

	spec, err := gen.GetSpec()
	if err != nil {
		t.Fatalf("load contract: %v", err)
	}
	if got := strconv.Itoa(info.ApiVersion); got != spec.Info.Version {
		t.Errorf("apiVersion = %s, want the contract version %s", got, spec.Info.Version)
	}
	if info.Hostname == "" || info.AgentVersion == "" || info.Features == nil {
		t.Errorf("info = %+v, want hostname, agent version and a features array", info)
	}
	if p.Port != 7443 {
		t.Errorf("pair reports port %d, want the configured 7443", p.Port)
	}
}

func TestWrongPinIsRejected(t *testing.T) {
	response, err := pinned("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA").Get("https://" + agent.addr + "/v1/info")
	if err == nil {
		_ = response.Body.Close()
		t.Fatal("connection with a foreign fingerprint succeeded")
	}
}

func TestWebSocketEchoesDebugEcho(t *testing.T) {
	client, token, _ := device(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	_, response, err := dial(ctx, client, "")
	if err == nil {
		t.Fatal("upgrade without a token succeeded")
	}
	if response == nil || response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("upgrade without a token: %v, want 401", err)
	}

	socket, response, err := dial(ctx, client, token)
	if err != nil {
		t.Fatalf("upgrade with a token: %v", err)
	}
	defer func() { _ = socket.CloseNow() }()
	if response.Header.Get("X-Request-Id") == "" {
		t.Error("upgrade response has no X-Request-Id")
	}

	write := func(text string) {
		t.Helper()
		if err := socket.Write(ctx, websocket.MessageText, []byte(text)); err != nil {
			t.Fatalf("write: %v", err)
		}
	}
	write(`{"type":"echo","ts":"2026-11-15T10:00:00.000Z","topic":"debug.echo","payload":{"n":1}}`)
	echo := readMessage(ctx, t, socket)
	if echo.Type != gen.WsMessageTypeEcho || echo.Topic == nil || *echo.Topic != "debug.echo" || string(echo.Payload) != `{"n":1}` {
		t.Fatalf("got %+v payload %s, want the echo of {\"n\":1} on debug.echo", echo, echo.Payload)
	}

	write(`{"type":"subscribe","ts":"2026-11-15T10:00:00.000Z","topic":"debug.echo","payload":{"requestId":"r1"}}`)
	if ack := readMessage(ctx, t, socket); ack.Type != gen.WsMessageTypeSubscribed {
		t.Fatalf("subscribe answered %s %s", ack.Type, ack.Payload)
	}
	write(`{"type":"echo","ts":"2026-11-15T10:00:00.000Z","topic":"debug.echo","payload":"again"}`)
	var event *message
	for range 2 {
		if msg := readMessage(ctx, t, socket); msg.Type == gen.WsMessageTypeEvent {
			event = &msg
		}
	}
	if event == nil || event.Seq == nil || *event.Seq != 1 || string(event.Payload) != `"again"` {
		t.Errorf("subscribed echo did not arrive as event seq 1: %+v", event)
	}
}

func TestWebSocketHeartbeat(t *testing.T) {
	client, token, _ := device(t)
	// The agent pings every 15 seconds.
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	socket, _, err := dial(ctx, client, token)
	if err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	defer func() { _ = socket.CloseNow() }()

	started := time.Now()
	if msg := readMessage(ctx, t, socket); msg.Type != gen.WsMessageTypePing {
		t.Fatalf("first message is %s, want ping", msg.Type)
	}
	if waited := time.Since(started); waited < 10*time.Second || waited > 20*time.Second {
		t.Errorf("ping arrived after %s, want about 15 seconds", waited.Round(time.Second))
	}
}

func TestRevokedTokenLosesAccess(t *testing.T) {
	client, token, tokenID := device(t)
	request, err := http.NewRequest(http.MethodGet, "https://"+agent.addr+"/v1/metrics/host", nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	request.Header.Set("Authorization", "Bearer "+token)

	response, err := client.Do(request)
	if err != nil {
		t.Fatalf("request before revoke: %v", err)
	}
	if response.StatusCode == http.StatusUnauthorized {
		t.Fatal("a fresh token was rejected")
	}
	_ = response.Body.Close()

	if _, err := docker("exec", agent.id, agentPath, "--fake", "tokens", "revoke", tokenID); err != nil {
		t.Fatalf("tokens revoke: %v", err)
	}
	response, err = client.Do(request)
	if err != nil {
		t.Fatalf("request after revoke: %v", err)
	}
	var body gen.Error
	decodeBody(t, response, http.StatusUnauthorized, &body)
	if body.Code != gen.Unauthorized {
		t.Errorf("error code = %q, want unauthorized", body.Code)
	}
}
