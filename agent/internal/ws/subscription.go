package ws

// event is a published payload with the sequence number it was assigned.
type event struct {
	seq     int64
	payload any
}

// subscription buffers events for one topic and parameter set on one connection.
type subscription struct {
	topic string
	key   string
	// requestIDs are the subscribe request ids that resolve to this
	// subscription: the first one plus any repeated subscribe.
	requestIDs []string

	seq     int64
	pending []event
	// dropped counts events discarded since the last drain; droppedSeq is the
	// sequence number of the latest one.
	dropped    int64
	droppedSeq int64
}

// push assigns the next sequence number and buffers the event. A full buffer
// discards its oldest event: a live stream is worth more than a complete one,
// and the client learns the loss from the gap that drain reports.
func (s *subscription) push(payload any, limit int) {
	s.seq++
	if len(s.pending) >= limit {
		s.dropped++
		s.droppedSeq = s.pending[0].seq
		copy(s.pending, s.pending[1:])
		s.pending = s.pending[:len(s.pending)-1]
	}
	s.pending = append(s.pending, event{seq: s.seq, payload: payload})
}

// drain hands over the buffered events. dropped is the number discarded before
// them, and gapSeq the sequence number the gap message carries, so that the
// first event after a gap continues the sequence.
func (s *subscription) drain() (dropped, gapSeq int64, events []event) {
	dropped, gapSeq, events = s.dropped, s.droppedSeq, s.pending
	s.dropped, s.pending = 0, nil
	return dropped, gapSeq, events
}
