package topics_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/coder/websocket"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/contracttest"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/collect/host"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/ws"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/ws/topics"
)

type message struct {
	Type    gen.WsMessageType `json:"type"`
	Topic   *string           `json:"topic"`
	Seq     *int64            `json:"seq"`
	Payload json.RawMessage   `json:"payload"`
}

// A subscriber to metrics.host receives the collector's snapshots as
// contract-valid HostMetrics events with increasing seq.
func TestMetricsHostStreamsCollectorSnapshots(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	hub, socket, logger := connect(ctx, t)

	subscribe := `{"type":"subscribe","ts":"2026-11-15T10:00:00.000Z","topic":"metrics.host","payload":{"requestId":"r1"}}`
	if err := socket.Write(ctx, websocket.MessageText, []byte(subscribe)); err != nil {
		t.Fatalf("subscribe: %v", err)
	}
	if ack := read(ctx, t, socket); ack.Type != gen.WsMessageTypeSubscribed {
		t.Fatalf("subscribe answered %s %s", ack.Type, ack.Payload)
	}

	proc := fstest.MapFS{
		"stat":    {Data: []byte("cpu  10 0 5 80 5 0 0 0\ncpu0 10 0 5 80 5 0 0 0\n")},
		"meminfo": {Data: []byte("MemTotal: 2048 kB\nMemAvailable: 1024 kB\n")},
	}
	collector := host.NewCollector(host.NewProcSampler(proc, time.Now), hub, topics.MetricsHost, 10*time.Millisecond, logger)
	go collector.Run(ctx)

	for want := int64(1); want <= 3; want++ {
		event := read(ctx, t, socket)
		if event.Type != gen.WsMessageTypeEvent || event.Topic == nil || *event.Topic != topics.MetricsHost {
			t.Fatalf("got %s on %v, want an event on metrics.host", event.Type, event.Topic)
		}
		if event.Seq == nil || *event.Seq != want {
			t.Errorf("seq = %v, want %d", event.Seq, want)
		}
		contracttest.RequireSchema(t, "HostMetrics", event.Payload)
	}
}

func TestMetricsHostTakesNoParameters(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, socket, _ := connect(ctx, t)

	subscribe := `{"type":"subscribe","ts":"2026-11-15T10:00:00.000Z","topic":"metrics.host","payload":{"requestId":"r1","params":{"projectId":"x"}}}`
	if err := socket.Write(ctx, websocket.MessageText, []byte(subscribe)); err != nil {
		t.Fatalf("subscribe: %v", err)
	}
	if reply := read(ctx, t, socket); reply.Type != gen.WsMessageTypeError {
		t.Errorf("subscribe with params answered %s, want error", reply.Type)
	}
}

// connect serves a hub with metrics.host registered and dials it.
func connect(ctx context.Context, t *testing.T) (*ws.Hub, *websocket.Conn, *slog.Logger) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	hub := ws.NewHub(ws.DefaultConfig(), time.Now, logger)
	topics.RegisterMetricsHost(hub)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hub.Handle(w, r, "req-1")
	}))
	t.Cleanup(func() {
		hub.Close()
		server.Close()
	})
	socket, response, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	if response.Body != nil {
		_ = response.Body.Close()
	}
	t.Cleanup(func() { _ = socket.CloseNow() })
	return hub, socket, logger
}

func read(ctx context.Context, t *testing.T, socket *websocket.Conn) message {
	t.Helper()
	_, data, err := socket.Read(ctx)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var msg message
	if err := json.Unmarshal(data, &msg); err != nil {
		t.Fatalf("decode %q: %v", data, err)
	}
	return msg
}
