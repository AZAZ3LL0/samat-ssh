package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/middleware"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/auth"
)

// version is the agent semver, set at release time with -ldflags "-X main.version=...".
var version = "0.0.0-dev"

const (
	purgeInterval   = 10 * time.Minute
	shutdownTimeout = 5 * time.Second
)

func runServe(ctx context.Context, e env, logOutput io.Writer) error {
	logger := slog.New(slog.NewJSONHandler(logOutput, nil))
	addr := net.JoinHostPort(e.cfg.Server.Host, strconv.Itoa(e.cfg.Server.Port))
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", addr, err)
	}
	return serve(ctx, e, listener, logger)
}

// serve runs the HTTPS API on listener until ctx is cancelled.
func serve(ctx context.Context, e env, listener net.Listener, logger *slog.Logger) error {
	hostname, err := os.Hostname()
	if err != nil {
		return fmt.Errorf("read hostname: %w", err)
	}
	certHost, err := advertiseHost(e.cfg)
	if err != nil {
		return err
	}
	cert, err := auth.LoadOrCreateCert(e.cfg.TLSDir(), certHost, time.Now())
	if err != nil {
		return err
	}
	fingerprint, err := auth.Fingerprint(cert)
	if err != nil {
		return err
	}
	handler, err := api.NewHandler(api.Deps{
		AgentVersion: version,
		Hostname:     hostname,
		Auth:         e.auth,
		Limiter:      auth.NewLimiter(time.Now),
		Logger:       logger,
	})
	if err != nil {
		return err
	}

	server := &http.Server{
		Handler:           handler,
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS13},
		ReadHeaderTimeout: 10 * time.Second,
		ErrorLog:          slog.NewLogLogger(logger.Handler(), slog.LevelWarn),
	}

	go purgeLoop(ctx, e, logger)
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), shutdownTimeout)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			logger.Warn("shutdown", "error", err)
		}
	}()

	logger.Info("listening", "addr", listener.Addr().String(), "version", version, "fingerprint", fingerprint)
	if err := server.ServeTLS(listener, "", ""); !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("serve: %w", err)
	}
	return nil
}

// purgeLoop drops idempotency records past their 24-hour life.
func purgeLoop(ctx context.Context, e env, logger *slog.Logger) {
	ticker := time.NewTicker(purgeInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			if err := e.store.PurgeIdempotency(ctx, now.Add(-middleware.IdempotencyTTL)); err != nil {
				logger.Warn("purge idempotency records", "error", err)
			}
		}
	}
}
