// Package ws multiplexes topics over one WebSocket per client: subscriptions,
// per-subscription sequence numbers, bounded buffers with gap reports and a
// heartbeat.
package ws

import (
	"errors"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// TopicDebugEcho echoes client payloads back; it exists to verify the skeleton.
const TopicDebugEcho = "debug.echo"

const shutdownReason = "agent is shutting down"

// Config holds the protocol limits. Tests shrink them; the agent uses DefaultConfig.
type Config struct {
	PingInterval     time.Duration
	IdleTimeout      time.Duration
	WriteTimeout     time.Duration
	MaxSubscriptions int
	BufferSize       int
	MaxMessageBytes  int64
}

// DefaultConfig returns the limits of the v1 protocol.
func DefaultConfig() Config {
	return Config{
		PingInterval:     15 * time.Second,
		IdleTimeout:      45 * time.Second,
		WriteTimeout:     10 * time.Second,
		MaxSubscriptions: 32,
		BufferSize:       1000,
		MaxMessageBytes:  64 << 10,
	}
}

// Topic is a stream clients can subscribe to.
type Topic struct {
	Name string
	// ValidateParams checks subscription parameters. Nil means the topic takes none.
	ValidateParams func(params map[string]any) error
}

// Hub tracks connections and fans published events out to their subscriptions.
type Hub struct {
	cfg    Config
	now    func() time.Time
	logger *slog.Logger

	wg sync.WaitGroup

	mu     sync.Mutex
	closed bool
	topics map[string]Topic
	conns  map[*conn]struct{}
}

// NewHub returns a hub serving debug.echo; other topics are added with Register.
func NewHub(cfg Config, now func() time.Time, logger *slog.Logger) *Hub {
	h := &Hub{
		cfg:    cfg,
		now:    now,
		logger: logger,
		topics: make(map[string]Topic),
		conns:  make(map[*conn]struct{}),
	}
	h.Register(Topic{Name: TopicDebugEcho})
	return h
}

// Register makes a topic available for subscription.
func (h *Hub) Register(topic Topic) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.topics[topic.Name] = topic
}

// Publish delivers payload as an event to every subscription of topic.
func (h *Hub) Publish(topic string, payload any) {
	h.mu.Lock()
	conns := make([]*conn, 0, len(h.conns))
	for c := range h.conns {
		conns = append(conns, c)
	}
	h.mu.Unlock()
	for _, c := range conns {
		c.publish(topic, payload)
	}
}

// Handle upgrades the request and serves the connection until it ends.
// requestID is the HTTP request id, reported in error payloads.
func (h *Hub) Handle(w http.ResponseWriter, r *http.Request, requestID string) {
	socket, err := websocket.Accept(w, r, nil)
	if err != nil {
		// Accept has already answered the client.
		h.logger.Debug("websocket upgrade", "error", err, "requestId", requestID)
		return
	}
	socket.SetReadLimit(h.cfg.MaxMessageBytes)

	c := newConn(h, socket, requestID)
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		_ = socket.Close(websocket.StatusGoingAway, shutdownReason)
		return
	}
	h.conns[c] = struct{}{}
	h.wg.Add(1)
	h.mu.Unlock()
	defer func() {
		h.mu.Lock()
		delete(h.conns, c)
		h.mu.Unlock()
		h.wg.Done()
	}()

	if err := c.run(); errors.Is(err, errSlowConsumer) {
		h.logger.Warn("websocket closed: client is not reading", "requestId", requestID)
	}
	_ = socket.CloseNow()
}

// Close ends every connection with a going-away close frame and waits for
// their handlers to return.
func (h *Hub) Close() {
	h.mu.Lock()
	h.closed = true
	conns := make([]*conn, 0, len(h.conns))
	for c := range h.conns {
		conns = append(conns, c)
	}
	h.mu.Unlock()
	for _, c := range conns {
		// Close performs the closing handshake, which also ends the reader.
		go func() { _ = c.socket.Close(websocket.StatusGoingAway, shutdownReason) }()
	}
	h.wg.Wait()
}

func (h *Hub) topic(name string) (Topic, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	topic, ok := h.topics[name]
	return topic, ok
}
