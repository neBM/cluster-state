package recycler

import (
	"fmt"
	"sync"

	"github.com/go-logr/logr"
)

// captureSink is a logr.LogSink that records each Info/Error message along
// with its key-value pairs rendered into a single string. Tests use
// containsMsg / containsKV to make assertions without coupling to zap.
type captureSink struct {
	mu   *sync.Mutex
	msgs *[]string
}

func (s *captureSink) Init(logr.RuntimeInfo) {}

func (s *captureSink) Enabled(level int) bool { return true }

func (s *captureSink) Info(level int, msg string, keysAndValues ...any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	*s.msgs = append(*s.msgs, msg+" "+renderKV(keysAndValues))
}

func (s *captureSink) Error(err error, msg string, keysAndValues ...any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	line := msg + " err=" + fmt.Sprintf("%v", err) + " " + renderKV(keysAndValues)
	*s.msgs = append(*s.msgs, line)
}

func (s *captureSink) WithValues(keysAndValues ...any) logr.LogSink { return s }

func (s *captureSink) WithName(name string) logr.LogSink { return s }

func renderKV(kv []any) string {
	out := ""
	for i := 0; i+1 < len(kv); i += 2 {
		if out != "" {
			out += " "
		}
		out += fmt.Sprintf("%v=%v", kv[i], kv[i+1])
	}
	return out
}

// newCaptureLogger returns a logr.Logger that records every log line and a
// closure returning a snapshot of the captured messages.
func newCaptureLogger() (logr.Logger, func() []string) {
	var mu sync.Mutex
	var msgs []string
	sink := &captureSink{mu: &mu, msgs: &msgs}
	return logr.New(sink), func() []string {
		mu.Lock()
		defer mu.Unlock()
		out := make([]string, len(msgs))
		copy(out, msgs)
		return out
	}
}
