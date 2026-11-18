package ws

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/oapi-codegen/nullable"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
)

// maxControlBacklog bounds replies queued for a client that stopped reading.
const maxControlBacklog = 1024

var errSlowConsumer = errors.New("ws: control backlog exceeded")

// conn is one client connection. The reader goroutine handles incoming
// messages, the writer goroutine is the only one that writes to the socket.
type conn struct {
	hub       *Hub
	socket    *websocket.Conn
	requestID string
	wake      chan struct{}

	mu        sync.Mutex
	control   []gen.WsEnvelope
	subs      map[string]*subscription // by topic + canonical params
	byRequest map[string]*subscription // by subscribe requestId
	overflow  bool
}

func newConn(hub *Hub, socket *websocket.Conn, requestID string) *conn {
	return &conn{
		hub:       hub,
		socket:    socket,
		requestID: requestID,
		wake:      make(chan struct{}, 1),
		subs:      make(map[string]*subscription),
		byRequest: make(map[string]*subscription),
	}
}

// run serves the connection until the client leaves or goes silent, the
// writer fails, or the hub closes the socket.
func (c *conn) run() error {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	writeErr := make(chan error, 1)
	go func() {
		err := c.write(ctx)
		if errors.Is(err, errSlowConsumer) {
			_ = c.socket.Close(websocket.StatusPolicyViolation, "client is not reading")
		} else if err != nil {
			// The socket is unusable; closing it unblocks the reader.
			_ = c.socket.CloseNow()
		}
		writeErr <- err
	}()

	for {
		// A client that sends nothing for IdleTimeout, not even pong, is dead.
		readCtx, stop := context.WithTimeout(context.Background(), c.hub.cfg.IdleTimeout)
		kind, data, err := c.socket.Read(readCtx)
		stop()
		if err != nil {
			cancel()
			if werr := <-writeErr; werr != nil {
				return werr
			}
			return err
		}
		if kind != websocket.MessageText {
			c.fail(nil, "", "messages must be JSON text frames")
			continue
		}
		c.handle(data)
	}
}

func (c *conn) write(ctx context.Context) error {
	ping := time.NewTicker(c.hub.cfg.PingInterval)
	defer ping.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ping.C:
			c.send(c.envelope(gen.WsMessageTypePing, nil, nil, nil))
		case <-c.wake:
		}
		envelopes, overflow := c.take()
		if overflow {
			return errSlowConsumer
		}
		for _, envelope := range envelopes {
			data, err := json.Marshal(envelope)
			if err != nil {
				return fmt.Errorf("encode %s message: %w", envelope.Type, err)
			}
			writeCtx, stop := context.WithTimeout(ctx, c.hub.cfg.WriteTimeout)
			err = c.socket.Write(writeCtx, websocket.MessageText, data)
			stop()
			if err != nil {
				return err
			}
		}
	}
}

// take collects everything ready to be written: replies first, then for each
// subscription a gap, if events were dropped, followed by its events.
func (c *conn) take() (envelopes []gen.WsEnvelope, overflow bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	envelopes, c.control = c.control, nil
	for _, sub := range c.subs {
		dropped, gapSeq, events := sub.drain()
		if dropped > 0 {
			envelopes = append(envelopes,
				c.envelope(gen.WsMessageTypeGap, &sub.topic, &gapSeq, gen.WsGapPayload{Dropped: dropped}))
		}
		for _, ev := range events {
			envelopes = append(envelopes, c.envelope(gen.WsMessageTypeEvent, &sub.topic, &ev.seq, ev.payload))
		}
	}
	return envelopes, c.overflow
}

func (c *conn) envelope(kind gen.WsMessageType, topic *string, seq *int64, payload any) gen.WsEnvelope {
	envelope := gen.WsEnvelope{
		Type:    kind,
		Ts:      c.hub.now().UTC().Truncate(time.Millisecond),
		Payload: payload,
	}
	if topic != nil {
		envelope.Topic = nullable.NewNullableWithValue(*topic)
	}
	if seq != nil {
		envelope.Seq = nullable.NewNullableWithValue(*seq)
	}
	return envelope
}

// send queues a reply for the writer.
func (c *conn) send(envelope gen.WsEnvelope) {
	c.mu.Lock()
	if len(c.control) >= maxControlBacklog {
		c.overflow = true
	} else {
		c.control = append(c.control, envelope)
	}
	c.mu.Unlock()
	c.signal()
}

func (c *conn) signal() {
	select {
	case c.wake <- struct{}{}:
	default:
	}
}

// publish buffers an event on every subscription of topic.
func (c *conn) publish(topic string, payload any) {
	c.mu.Lock()
	matched := false
	for _, sub := range c.subs {
		if sub.topic == topic {
			sub.push(payload, c.hub.cfg.BufferSize)
			matched = true
		}
	}
	c.mu.Unlock()
	if matched {
		c.signal()
	}
}

// fail reports a rejected message. wsRequestID, when the message carried one,
// lets the client match the error to its request.
func (c *conn) fail(topic *string, wsRequestID, message string) {
	payload := gen.Error{Code: gen.InvalidRequest, Message: message, RequestId: c.requestID}
	if wsRequestID != "" {
		payload.Details = &map[string]any{"requestId": wsRequestID}
	}
	c.send(c.envelope(gen.WsMessageTypeError, topic, nil, payload))
}

func (c *conn) handle(data []byte) {
	var envelope gen.WsEnvelope
	if err := json.Unmarshal(data, &envelope); err != nil {
		c.fail(nil, "", "malformed envelope")
		return
	}
	var topic *string
	if name, err := envelope.Topic.Get(); err == nil {
		topic = &name
	}

	switch envelope.Type {
	case gen.WsMessageTypeSubscribe:
		c.subscribe(topic, envelope.Payload)
	case gen.WsMessageTypeUnsubscribe:
		c.unsubscribe(topic, envelope.Payload)
	case gen.WsMessageTypePong:
		// Reading it already reset the idle timer.
	case gen.WsMessageTypeEcho:
		c.echo(topic, envelope.Payload)
	default:
		c.fail(topic, "", fmt.Sprintf("message type %q is not accepted from a client", envelope.Type))
	}
}

func (c *conn) subscribe(topicName *string, rawPayload any) {
	payload, err := decodePayload[gen.WsSubscribePayload](rawPayload)
	if err != nil || payload.RequestId == "" {
		c.fail(topicName, "", "subscribe needs a payload with requestId")
		return
	}
	if topicName == nil {
		c.fail(nil, payload.RequestId, "subscribe needs a topic")
		return
	}
	topic, ok := c.hub.topic(*topicName)
	if !ok {
		c.fail(topicName, payload.RequestId, "unknown topic")
		return
	}
	params := map[string]any{}
	if payload.Params != nil {
		params = *payload.Params
	}
	if topic.ValidateParams == nil && len(params) > 0 {
		c.fail(topicName, payload.RequestId, "topic takes no parameters")
		return
	}
	if topic.ValidateParams != nil {
		if err := topic.ValidateParams(params); err != nil {
			c.fail(topicName, payload.RequestId, "invalid subscription parameters: "+err.Error())
			return
		}
	}
	// encoding/json writes map keys sorted, which makes the encoding canonical.
	canonical, err := json.Marshal(params)
	if err != nil {
		c.fail(topicName, payload.RequestId, "invalid subscription parameters")
		return
	}
	key := topic.Name + "\x00" + string(canonical)

	c.mu.Lock()
	sub, exists := c.subs[key]
	owner, idTaken := c.byRequest[payload.RequestId]
	switch {
	case idTaken && owner != sub:
		c.mu.Unlock()
		c.fail(topicName, payload.RequestId, "requestId already identifies another subscription")
		return
	case !exists && len(c.subs) >= c.hub.cfg.MaxSubscriptions:
		c.mu.Unlock()
		c.fail(topicName, payload.RequestId, fmt.Sprintf("at most %d subscriptions per connection", c.hub.cfg.MaxSubscriptions))
		return
	case !exists:
		sub = &subscription{topic: topic.Name, key: key}
		c.subs[key] = sub
	}
	if !idTaken {
		sub.requestIDs = append(sub.requestIDs, payload.RequestId)
		c.byRequest[payload.RequestId] = sub
	}
	c.mu.Unlock()

	c.send(c.envelope(gen.WsMessageTypeSubscribed, topicName, nil, gen.WsSubscribedPayload{RequestId: payload.RequestId}))
}

func (c *conn) unsubscribe(topicName *string, rawPayload any) {
	payload, err := decodePayload[gen.WsUnsubscribePayload](rawPayload)
	if err != nil || payload.RequestId == "" {
		c.fail(topicName, "", "unsubscribe needs a payload with requestId")
		return
	}
	c.mu.Lock()
	sub, ok := c.byRequest[payload.RequestId]
	if ok {
		delete(c.subs, sub.key)
		for _, id := range sub.requestIDs {
			delete(c.byRequest, id)
		}
	}
	c.mu.Unlock()
	if !ok {
		c.fail(topicName, payload.RequestId, "no subscription with this requestId")
	}
}

// echo answers on debug.echo. A connection subscribed to the topic also gets
// the payload as an event, which exercises the subscription path end to end.
func (c *conn) echo(topicName *string, payload any) {
	if topicName == nil || *topicName != TopicDebugEcho {
		c.fail(topicName, "", "echo is accepted only on "+TopicDebugEcho)
		return
	}
	c.send(c.envelope(gen.WsMessageTypeEcho, topicName, nil, payload))
	c.publish(TopicDebugEcho, payload)
}

// decodePayload converts the envelope's untyped payload into a contract type.
func decodePayload[T any](raw any) (T, error) {
	var payload T
	if raw == nil {
		return payload, errors.New("payload is missing")
	}
	data, err := json.Marshal(raw)
	if err != nil {
		return payload, err
	}
	err = json.Unmarshal(data, &payload)
	return payload, err
}
