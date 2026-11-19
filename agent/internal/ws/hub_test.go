package ws_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/apitime"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/ws"
)

const (
	topicTicks = "test.ticks"
	// topicFiles takes parameters, like the log topics of later slices.
	topicFiles = "test.files"
)

// message mirrors the wire shape of WsEnvelope with the payload left raw, so
// each test decodes it into the contract type it expects.
type message struct {
	Type    gen.WsMessageType `json:"type"`
	Topic   *string           `json:"topic"`
	Seq     *int64            `json:"seq"`
	Ts      string            `json:"ts"`
	Payload json.RawMessage   `json:"payload"`
}

type client struct {
	t      *testing.T
	socket *websocket.Conn
}

func startHub(t *testing.T, cfg ws.Config) (*ws.Hub, string) {
	t.Helper()
	hub := ws.NewHub(cfg, time.Now, slog.New(slog.NewTextHandler(io.Discard, nil)))
	hub.Register(ws.Topic{Name: topicTicks})
	hub.Register(ws.Topic{Name: topicFiles, ValidateParams: func(params map[string]any) error {
		if _, ok := params["path"].(string); !ok {
			return errors.New("path is required")
		}
		return nil
	}})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hub.Handle(w, r, "http-request-1")
	}))
	t.Cleanup(func() {
		hub.Close()
		server.Close()
	})
	return hub, "ws" + strings.TrimPrefix(server.URL, "http")
}

func dial(t *testing.T, url string) *client {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	socket, response, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	if response.Body != nil {
		_ = response.Body.Close()
	}
	socket.SetReadLimit(1 << 20)
	t.Cleanup(func() { _ = socket.CloseNow() })
	return &client{t: t, socket: socket}
}

func (c *client) send(kind gen.WsMessageType, topic string, payload any) {
	c.t.Helper()
	envelope := map[string]any{"type": kind, "ts": time.Now().UTC().Format(time.RFC3339Nano)}
	if topic != "" {
		envelope["topic"] = topic
	}
	if payload != nil {
		envelope["payload"] = payload
	}
	data, err := json.Marshal(envelope)
	if err != nil {
		c.t.Fatalf("encode: %v", err)
	}
	c.sendRaw(string(data))
}

func (c *client) sendRaw(text string) {
	c.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.socket.Write(ctx, websocket.MessageText, []byte(text)); err != nil {
		c.t.Fatalf("write: %v", err)
	}
}

// read returns the next message that is not a ping.
func (c *client) read() message {
	c.t.Helper()
	for {
		msg, err := c.readAny(5 * time.Second)
		if err != nil {
			c.t.Fatalf("read: %v", err)
		}
		if msg.Type != gen.WsMessageTypePing {
			return msg
		}
	}
}

func (c *client) readAny(timeout time.Duration) (message, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	_, data, err := c.socket.Read(ctx)
	if err != nil {
		return message{}, err
	}
	var msg message
	if err := json.Unmarshal(data, &msg); err != nil {
		c.t.Fatalf("server sent %q: %v", data, err)
	}
	if !msg.Type.Valid() {
		c.t.Errorf("server sent unknown message type %q", msg.Type)
	}
	if _, err := time.Parse(apitime.Layout, msg.Ts); err != nil {
		c.t.Errorf("ts %q is not RFC 3339 UTC with milliseconds", msg.Ts)
	}
	return msg, nil
}

func (c *client) subscribe(topic, requestID string, params map[string]any) {
	c.t.Helper()
	payload := map[string]any{"requestId": requestID}
	if params != nil {
		payload["params"] = params
	}
	c.send(gen.WsMessageTypeSubscribe, topic, payload)
	msg := c.read()
	if msg.Type != gen.WsMessageTypeSubscribed {
		c.t.Fatalf("subscribe %s answered %s %s", requestID, msg.Type, msg.Payload)
	}
	var ack gen.WsSubscribedPayload
	decode(c.t, msg.Payload, &ack)
	if ack.RequestId != requestID {
		c.t.Fatalf("subscribed requestId = %q, want %q", ack.RequestId, requestID)
	}
}

func (c *client) wantError(wsRequestID string) {
	c.t.Helper()
	msg := c.read()
	if msg.Type != gen.WsMessageTypeError {
		c.t.Fatalf("got %s %s, want error", msg.Type, msg.Payload)
	}
	var payload gen.Error
	decode(c.t, msg.Payload, &payload)
	if payload.Code != gen.InvalidRequest {
		c.t.Errorf("error code = %q, want invalid_request", payload.Code)
	}
	if payload.RequestId != "http-request-1" {
		c.t.Errorf("error requestId = %q, want the HTTP request id", payload.RequestId)
	}
	if wsRequestID != "" {
		if payload.Details == nil || (*payload.Details)["requestId"] != wsRequestID {
			c.t.Errorf("error details = %v, want requestId %q", payload.Details, wsRequestID)
		}
	}
}

func decode(t *testing.T, raw json.RawMessage, into any) {
	t.Helper()
	if err := json.Unmarshal(raw, into); err != nil {
		t.Fatalf("decode payload %q: %v", raw, err)
	}
}

func quiet() ws.Config {
	cfg := ws.DefaultConfig()
	cfg.PingInterval = time.Hour
	return cfg
}

func TestEchoRoundTrip(t *testing.T) {
	_, url := startHub(t, quiet())
	c := dial(t, url)
	c.send(gen.WsMessageTypeEcho, ws.TopicDebugEcho, map[string]any{"hello": "pulse", "n": 7})

	msg := c.read()
	if msg.Type != gen.WsMessageTypeEcho || msg.Topic == nil || *msg.Topic != ws.TopicDebugEcho {
		t.Fatalf("got %+v, want echo on debug.echo", msg)
	}
	if msg.Seq != nil {
		t.Errorf("echo carries seq %d; seq belongs to event and gap only", *msg.Seq)
	}
	var payload map[string]any
	decode(t, msg.Payload, &payload)
	if payload["hello"] != "pulse" || payload["n"] != 7.0 {
		t.Errorf("payload = %v, want the one sent", payload)
	}
}

func TestSubscriptionDeliversEventsWithMonotonicSeq(t *testing.T) {
	hub, url := startHub(t, quiet())
	c := dial(t, url)
	c.subscribe(topicTicks, "r1", nil)

	for i := range 5 {
		hub.Publish(topicTicks, map[string]int{"tick": i})
	}
	for i := range 5 {
		msg := c.read()
		if msg.Type != gen.WsMessageTypeEvent || msg.Topic == nil || *msg.Topic != topicTicks {
			t.Fatalf("message %d = %+v, want event on %s", i, msg, topicTicks)
		}
		if msg.Seq == nil || *msg.Seq != int64(i+1) {
			t.Fatalf("message %d seq = %v, want %d", i, msg.Seq, i+1)
		}
		var payload map[string]int
		decode(t, msg.Payload, &payload)
		if payload["tick"] != i {
			t.Errorf("message %d payload = %v", i, payload)
		}
	}
}

func TestEventsReachOnlySubscribers(t *testing.T) {
	hub, url := startHub(t, quiet())
	subscriber, bystander := dial(t, url), dial(t, url)
	subscriber.subscribe(topicTicks, "r1", nil)
	// The echo proves the bystander's connection is registered before publishing.
	bystander.send(gen.WsMessageTypeEcho, ws.TopicDebugEcho, "ready")
	bystander.read()

	hub.Publish(topicTicks, "tick")
	if msg := subscriber.read(); msg.Type != gen.WsMessageTypeEvent {
		t.Fatalf("subscriber got %s, want event", msg.Type)
	}
	bystander.send(gen.WsMessageTypeEcho, ws.TopicDebugEcho, "after")
	if msg := bystander.read(); msg.Type != gen.WsMessageTypeEcho {
		t.Errorf("bystander got %s %s before its echo", msg.Type, msg.Payload)
	}
}

func TestRepeatedSubscribeIsNoOp(t *testing.T) {
	hub, url := startHub(t, quiet())
	c := dial(t, url)
	c.subscribe(topicFiles, "r1", map[string]any{"path": "/var/log/a", "since": "x"})
	// Same parameters in another key order are the same subscription.
	c.subscribe(topicFiles, "r2", map[string]any{"since": "x", "path": "/var/log/a"})

	hub.Publish(topicFiles, "line")
	c.send(gen.WsMessageTypeEcho, ws.TopicDebugEcho, "marker")
	first, second := c.read(), c.read()
	if first.Type != gen.WsMessageTypeEvent || second.Type != gen.WsMessageTypeEcho {
		t.Fatalf("got %s then %s, want exactly one event before the marker", first.Type, second.Type)
	}
}

func TestUnsubscribeStopsEvents(t *testing.T) {
	hub, url := startHub(t, quiet())
	c := dial(t, url)
	c.subscribe(topicTicks, "r1", nil)
	c.send(gen.WsMessageTypeUnsubscribe, topicTicks, map[string]any{"requestId": "r1"})
	// The echo is handled after the unsubscribe, so it marks its completion.
	c.send(gen.WsMessageTypeEcho, ws.TopicDebugEcho, "unsubscribed")
	if msg := c.read(); msg.Type != gen.WsMessageTypeEcho {
		t.Fatalf("got %s, want echo", msg.Type)
	}

	hub.Publish(topicTicks, "tick")
	c.send(gen.WsMessageTypeEcho, ws.TopicDebugEcho, "marker")
	if msg := c.read(); msg.Type != gen.WsMessageTypeEcho {
		t.Errorf("got %s %s after unsubscribe, want only the marker", msg.Type, msg.Payload)
	}

	c.send(gen.WsMessageTypeUnsubscribe, topicTicks, map[string]any{"requestId": "r1"})
	c.wantError("r1")
}

func TestSubscribedDebugEchoAlsoGetsEvent(t *testing.T) {
	_, url := startHub(t, quiet())
	c := dial(t, url)
	c.subscribe(ws.TopicDebugEcho, "r1", nil)
	c.send(gen.WsMessageTypeEcho, ws.TopicDebugEcho, "ping-1")

	kinds := map[gen.WsMessageType]message{}
	for range 2 {
		msg := c.read()
		kinds[msg.Type] = msg
	}
	event, ok := kinds[gen.WsMessageTypeEvent]
	if _, hasEcho := kinds[gen.WsMessageTypeEcho]; !ok || !hasEcho {
		t.Fatalf("got %v, want one echo and one event", kinds)
	}
	if event.Seq == nil || *event.Seq != 1 || string(event.Payload) != `"ping-1"` {
		t.Errorf("event = seq %v payload %s, want seq 1 with the echoed payload", event.Seq, event.Payload)
	}
}

func TestThirtyThirdSubscriptionIsRejected(t *testing.T) {
	_, url := startHub(t, quiet())
	c := dial(t, url)
	for i := range 32 {
		c.subscribe(topicFiles, fmt.Sprintf("r%d", i), map[string]any{"path": fmt.Sprintf("/var/log/%d", i)})
	}
	c.send(gen.WsMessageTypeSubscribe, topicFiles, map[string]any{"requestId": "r32", "params": map[string]any{"path": "/var/log/32"}})
	c.wantError("r32")
	// A repeat of an existing subscription is still a no-op at the limit.
	c.subscribe(topicFiles, "again", map[string]any{"path": "/var/log/0"})
}

func TestInvalidMessagesAnswerWithError(t *testing.T) {
	_, url := startHub(t, quiet())
	c := dial(t, url)
	c.subscribe(topicTicks, "taken", nil)

	for name, tc := range map[string]struct {
		raw         string
		wsRequestID string
	}{
		"malformed json":       {raw: `{"type":`},
		"unknown topic":        {raw: `{"type":"subscribe","ts":"2026-11-15T10:00:00.000Z","topic":"nope","payload":{"requestId":"a"}}`, wsRequestID: "a"},
		"no topic":             {raw: `{"type":"subscribe","ts":"2026-11-15T10:00:00.000Z","payload":{"requestId":"b"}}`, wsRequestID: "b"},
		"no requestId":         {raw: `{"type":"subscribe","ts":"2026-11-15T10:00:00.000Z","topic":"test.ticks","payload":{}}`},
		"params not accepted":  {raw: `{"type":"subscribe","ts":"2026-11-15T10:00:00.000Z","topic":"test.ticks","payload":{"requestId":"c","params":{"x":1}}}`, wsRequestID: "c"},
		"params invalid":       {raw: `{"type":"subscribe","ts":"2026-11-15T10:00:00.000Z","topic":"test.files","payload":{"requestId":"d","params":{}}}`, wsRequestID: "d"},
		"requestId reused":     {raw: `{"type":"subscribe","ts":"2026-11-15T10:00:00.000Z","topic":"test.files","payload":{"requestId":"taken","params":{"path":"/a"}}}`, wsRequestID: "taken"},
		"server-only type":     {raw: `{"type":"event","ts":"2026-11-15T10:00:00.000Z","topic":"test.ticks","payload":{}}`},
		"echo on other topic":  {raw: `{"type":"echo","ts":"2026-11-15T10:00:00.000Z","topic":"test.ticks","payload":1}`},
		"unknown message type": {raw: `{"type":"shout","ts":"2026-11-15T10:00:00.000Z"}`},
	} {
		t.Run(name, func(t *testing.T) {
			c.t = t
			c.sendRaw(tc.raw)
			c.wantError(tc.wsRequestID)
		})
	}
}

// With nobody reading, the buffer keeps the newest events and reports the
// rest: everything published is either delivered or counted in a gap, and
// seq never goes backwards.
func TestOverflowReportsGap(t *testing.T) {
	cfg := quiet()
	cfg.BufferSize = 16
	hub, url := startHub(t, cfg)
	c := dial(t, url)
	c.subscribe(topicTicks, "r1", nil)

	const published = 3000
	blob := strings.Repeat("x", 8<<10)
	for range published {
		hub.Publish(topicTicks, blob)
	}

	// The newest event is never dropped, so its seq marks the end of the stream.
	var delivered, dropped, lastSeq int64
	gaps := 0
	for lastSeq < published {
		msg := c.read()
		if msg.Seq == nil || *msg.Seq <= lastSeq {
			t.Fatalf("%s seq = %v after %d, want a larger one", msg.Type, msg.Seq, lastSeq)
		}
		switch msg.Type {
		case gen.WsMessageTypeEvent:
			delivered++
		case gen.WsMessageTypeGap:
			var gap gen.WsGapPayload
			decode(t, msg.Payload, &gap)
			if gap.Dropped <= 0 {
				t.Errorf("gap reports %d dropped events", gap.Dropped)
			}
			dropped += gap.Dropped
			gaps++
		default:
			t.Fatalf("unexpected %s", msg.Type)
		}
		lastSeq = *msg.Seq
	}
	if gaps == 0 {
		t.Fatal("no gap although the client was not reading; the buffer is unbounded or drops silently")
	}
	if delivered+dropped != published {
		t.Errorf("delivered %d + dropped %d; want them to account for all %d events", delivered, dropped, published)
	}
}

func TestServerPingsAndDropsSilentClient(t *testing.T) {
	cfg := ws.DefaultConfig()
	cfg.PingInterval = 30 * time.Millisecond
	cfg.IdleTimeout = 150 * time.Millisecond
	_, url := startHub(t, cfg)
	c := dial(t, url)

	msg, err := c.readAny(2 * time.Second)
	if err != nil || msg.Type != gen.WsMessageTypePing {
		t.Fatalf("first message = %+v, %v; want ping", msg, err)
	}
	// The client never answers, so the server must give up on it.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := c.readAny(time.Second); err != nil {
			return
		}
	}
	t.Fatal("silent client is still connected long after the idle timeout")
}

func TestPongKeepsConnectionAlive(t *testing.T) {
	cfg := ws.DefaultConfig()
	cfg.PingInterval = 30 * time.Millisecond
	cfg.IdleTimeout = 150 * time.Millisecond
	_, url := startHub(t, cfg)
	c := dial(t, url)

	alive := time.Now().Add(5 * cfg.IdleTimeout)
	for time.Now().Before(alive) {
		msg, err := c.readAny(time.Second)
		if err != nil {
			t.Fatalf("connection dropped although the client answers pings: %v", err)
		}
		if msg.Type == gen.WsMessageTypePing {
			c.send(gen.WsMessageTypePong, "", nil)
		}
	}
}

func TestCloseDisconnectsClients(t *testing.T) {
	hub, url := startHub(t, quiet())
	c := dial(t, url)
	c.send(gen.WsMessageTypeEcho, ws.TopicDebugEcho, "ready")
	c.read()

	done := make(chan struct{})
	go func() {
		hub.Close()
		close(done)
	}()
	if _, err := c.readAny(3 * time.Second); websocket.CloseStatus(err) != websocket.StatusGoingAway {
		t.Errorf("read after Close: %v, want close status going away", err)
	}
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("Close did not return")
	}
}
