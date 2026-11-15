package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
)

// pinnedClient trusts exactly one key, the way the app does: the connection
// fails unless the server's SPKI hash equals the fingerprint from pairing.
func pinnedClient(fingerprint string) *http.Client {
	return &http.Client{
		Timeout: 5 * time.Second,
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

func startAgent(t *testing.T, configPath string) (baseURL string) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- withEnv(ctx, configPath, false, func(e env) error {
			return serve(ctx, e, listener, slog.New(slog.NewTextHandler(io.Discard, nil)))
		})
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case err := <-done:
			if err != nil {
				t.Errorf("agent stopped with %v, want a clean shutdown", err)
			}
		case <-time.After(10 * time.Second):
			t.Error("agent did not stop after cancellation")
		}
	})
	return "https://" + listener.Addr().String()
}

func TestAgentServesPairedDeviceOverPinnedTLS(t *testing.T) {
	configPath := writeConfig(t)
	baseURL := startAgent(t, configPath)
	p := pairJSON(t, configPath)
	client := pinnedClient(p.FP)

	response, err := client.Get(baseURL + "/v1/info")
	if err != nil {
		t.Fatalf("GET /v1/info with the fingerprint printed by `pair`: %v", err)
	}
	var info gen.AgentInfo
	decodeResponse(t, response, http.StatusOK, &info)
	if info.ApiVersion < 1 || info.AgentVersion == "" {
		t.Errorf("info = %+v, want a core version and an agent version", info)
	}

	response, err = client.Post(baseURL+"/v1/pair", "application/json",
		strings.NewReader(`{"code":"`+p.Code+`","deviceName":"iPhone"}`))
	if err != nil {
		t.Fatalf("POST /v1/pair: %v", err)
	}
	var paired gen.PairResponse
	decodeResponse(t, response, http.StatusOK, &paired)

	request, err := http.NewRequest(http.MethodGet, baseURL+"/v1/metrics/host", nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	request.Header.Set("Authorization", "Bearer "+paired.Token)
	response, err = client.Do(request)
	if err != nil {
		t.Fatalf("GET /v1/metrics/host: %v", err)
	}
	var notReady gen.Error
	decodeResponse(t, response, http.StatusNotImplemented, &notReady)

	if out, err := runCLI(t, configPath, "tokens", "revoke", paired.TokenId); err != nil {
		t.Fatalf("tokens revoke: %v (%s)", err, out)
	}
	response, err = client.Do(request)
	if err != nil {
		t.Fatalf("GET /v1/metrics/host after revoke: %v", err)
	}
	var revoked gen.Error
	decodeResponse(t, response, http.StatusUnauthorized, &revoked)
	if revoked.Code != gen.Unauthorized {
		t.Errorf("error code after revoke = %q, want unauthorized", revoked.Code)
	}
}

func TestAgentRejectsWrongPin(t *testing.T) {
	configPath := writeConfig(t)
	baseURL := startAgent(t, configPath)
	other := pairJSON(t, writeConfig(t))

	response, err := pinnedClient(other.FP).Get(baseURL + "/v1/info")
	if err == nil {
		_ = response.Body.Close()
		t.Fatal("connection with another agent's fingerprint succeeded")
	}
}

func decodeResponse(t *testing.T, response *http.Response, status int, into any) {
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
