package main

import (
	"testing"
	"time"
)

func TestEventQueueOverflowMarker(t *testing.T) {
	q := newEventQueue(3)
	for i := 0; i < 10; i++ {
		q.push(map[string]any{"kind": "change", "i": i})
	}
	evs, err := q.poll(0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 4 {
		t.Fatalf("got %d events, want 3 + one overflow marker", len(evs))
	}
	last := evs[3]
	if last["kind"] != "overflow" || last["dropped"] != 7 {
		t.Fatalf("marker = %v, want overflow with 7 dropped", last)
	}
	// Once read, the queue accepts events again.
	q.push(map[string]any{"kind": "change"})
	if evs, _ := q.poll(0, 0); len(evs) != 1 || evs[0]["kind"] != "change" {
		t.Fatalf("after the marker: %v", evs)
	}
}

func TestEventQueuePollMaxAndTimeout(t *testing.T) {
	q := newEventQueue(10)
	for i := 0; i < 5; i++ {
		q.push(map[string]any{"i": i})
	}
	evs, _ := q.poll(2, 0)
	if len(evs) != 2 || evs[0]["i"] != 0 || evs[1]["i"] != 1 {
		t.Fatalf("first poll: %v", evs)
	}
	evs, _ = q.poll(10, 0)
	if len(evs) != 3 || evs[0]["i"] != 2 {
		t.Fatalf("second poll: %v", evs)
	}
	start := time.Now()
	evs, err := q.poll(10, 50*time.Millisecond)
	if err != nil || len(evs) != 0 || time.Since(start) < 40*time.Millisecond {
		t.Fatalf("empty poll: %v %v after %v", evs, err, time.Since(start))
	}
}

func TestEventQueuePollWakesOnPushAndClose(t *testing.T) {
	q := newEventQueue(10)
	go func() {
		time.Sleep(20 * time.Millisecond)
		q.push(map[string]any{"kind": "change"})
	}()
	evs, err := q.poll(10, 5*time.Second)
	if err != nil || len(evs) != 1 {
		t.Fatalf("push did not wake the poller: %v %v", evs, err)
	}
	done := make(chan error)
	go func() {
		_, err := q.poll(10, 10*time.Second)
		done <- err
	}()
	time.Sleep(20 * time.Millisecond)
	q.close()
	select {
	case err := <-done:
		if codeOf(err) != codeClosed {
			t.Fatalf("poll after close: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("close did not wake the poller")
	}
	q.push(map[string]any{"kind": "change"}) // no panic after close
}
