package ws

import "testing"

// Ten events into a buffer of four: the six oldest are dropped, the gap says
// so and carries the last dropped seq, and the survivors continue from it.
func TestOverflowDropsOldestAndCountsThem(t *testing.T) {
	sub := &subscription{}
	for i := 1; i <= 10; i++ {
		sub.push(i, 4)
	}
	dropped, gapSeq, events := sub.drain()
	if dropped != 6 || gapSeq != 6 {
		t.Fatalf("dropped = %d, gap seq = %d; want 6 and 6", dropped, gapSeq)
	}
	if len(events) != 4 {
		t.Fatalf("kept %d events, want 4", len(events))
	}
	for i, ev := range events {
		if want := int64(7 + i); ev.seq != want || ev.payload != int(want) {
			t.Errorf("event %d = seq %d payload %v, want %d", i, ev.seq, ev.payload, want)
		}
	}
}

func TestDrainResetsTheGapButNotTheSequence(t *testing.T) {
	sub := &subscription{}
	for i := 1; i <= 6; i++ {
		sub.push(i, 4)
	}
	sub.drain()

	sub.push(7, 4)
	dropped, _, events := sub.drain()
	if dropped != 0 {
		t.Errorf("dropped = %d after a drain with no new overflow, want 0", dropped)
	}
	if len(events) != 1 || events[0].seq != 7 {
		t.Errorf("events = %+v, want one event with seq 7", events)
	}
}
