package main

import (
	"bufio"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestServer(redisAddr string) *server {
	cfg := loadConfig()
	cfg.podName = "test-pod"
	cfg.color = "#123456"
	return &server{cfg: cfg, redis: NewRedis(redisAddr, 2), metrics: &metrics{requests: map[string]int64{}}}
}

func TestHealthAndReadiness(t *testing.T) {
	s := newTestServer("127.0.0.1:1")
	rec := httptest.NewRecorder()
	s.handleHealthz(rec, httptest.NewRequest("GET", "/healthz", nil))
	if rec.Code != 200 {
		t.Fatalf("healthz = %d", rec.Code)
	}
	rec = httptest.NewRecorder()
	s.handleReadyz(rec, httptest.NewRequest("GET", "/readyz", nil))
	if rec.Code != 200 {
		t.Fatalf("readyz = %d", rec.Code)
	}
	s.shuttingDown.Store(true)
	rec = httptest.NewRecorder()
	s.handleReadyz(rec, httptest.NewRequest("GET", "/readyz", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("readyz while shutting down = %d, want 503", rec.Code)
	}
}

func TestInfoDegradesWithoutRedis(t *testing.T) {
	s := newTestServer("127.0.0.1:1") // nothing listens there
	rec := httptest.NewRecorder()
	s.handleInfo(rec, httptest.NewRequest("GET", "/api/info", nil))
	if rec.Code != 200 {
		t.Fatalf("info = %d, want 200 even without Redis", rec.Code)
	}
	var resp infoResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Redis == "ok" || resp.Served.Name != "test-pod" || len(resp.Pods) != 1 {
		t.Fatalf("unexpected response: %+v", resp)
	}
}

// fakeRedis speaks just enough RESP to answer a fixed script of replies.
func fakeRedis(t *testing.T, replies ...string) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		r := bufio.NewReader(c)
		for _, reply := range replies {
			// read one command: "*N" then N pairs of "$len" + value
			line, err := r.ReadString('\n')
			if err != nil {
				return
			}
			n := 0
			for _, ch := range strings.TrimSpace(line[1:]) {
				n = n*10 + int(ch-'0')
			}
			for i := 0; i < 2*n; i++ {
				if _, err := r.ReadString('\n'); err != nil {
					return
				}
			}
			c.Write([]byte(reply))
		}
	}()
	return ln.Addr().String()
}

func TestRedisReplies(t *testing.T) {
	addr := fakeRedis(t,
		"+PONG\r\n",
		":42\r\n",
		"*4\r\n$1\r\na\r\n$1\r\n1\r\n$1\r\nb\r\n$-1\r\n",
		"-ERR wrong type\r\n",
	)
	r := NewRedis(addr, 1)
	if err := r.Ping(); err != nil {
		t.Fatal(err)
	}
	if n, err := r.Incr("x"); err != nil || n != 42 {
		t.Fatalf("incr = %d, %v", n, err)
	}
	m, err := r.HGetAll("h")
	if err != nil || m["a"] != "1" || m["b"] != "" {
		t.Fatalf("hgetall = %v, %v", m, err)
	}
	if _, err := r.Incr("x"); err == nil || !strings.Contains(err.Error(), "wrong type") {
		t.Fatalf("expected redis error, got %v", err)
	}
}

func TestWorkCapsDuration(t *testing.T) {
	s := newTestServer("127.0.0.1:1")
	rec := httptest.NewRecorder()
	s.handleWork(rec, httptest.NewRequest("GET", "/api/work?ms=5", nil))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "worked 5ms") {
		t.Fatalf("work: %d %q", rec.Code, rec.Body.String())
	}
}
