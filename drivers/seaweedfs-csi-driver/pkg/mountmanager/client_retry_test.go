package mountmanager

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"syscall"
	"testing"
)

func TestShouldRetryDial(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"raw ENOENT", syscall.ENOENT, true},
		{"raw ECONNREFUSED", syscall.ECONNREFUSED, true},
		{"net.OpError dial ENOENT", &net.OpError{Op: "dial", Err: syscall.ENOENT}, true},
		{"net.OpError read EOF", &net.OpError{Op: "read", Err: io.EOF}, false},
		{"url.Error wrapping dial", &url.Error{Op: "Post", URL: "http://unix/mount", Err: &net.OpError{Op: "dial", Err: syscall.ENOENT}}, true},
		{"plain http 500-style error", fmt.Errorf("500 Internal Server Error"), false},
		{"context.Canceled", context.Canceled, false},
		{"context.DeadlineExceeded", context.DeadlineExceeded, false},
		{"wrapped ENOENT via fmt.Errorf %w", fmt.Errorf("dial: %w", syscall.ENOENT), true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := shouldRetryDial(c.err)
			if got != c.want {
				t.Errorf("shouldRetryDial(%v) = %v, want %v", c.err, got, c.want)
			}
		})
	}
	// Sanity: errors.Is unwrapping should work
	wrapped := fmt.Errorf("outer: %w", &net.OpError{Op: "dial", Err: syscall.ECONNREFUSED})
	if !errors.Is(wrapped, syscall.ECONNREFUSED) {
		t.Skip("errors.Is doesn't unwrap as expected — test fixture is wrong")
	}
}
