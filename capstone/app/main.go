// Pulse: a small web app built to SHOW what Kubernetes is doing.
//
// The page polls /api/info several times a second. Every response says which Pod (and which
// version, colour and node) served it, and a shared hit counter lives in Redis. So you can
// watch load balancing, scaling, self-healing and zero-downtime rolling updates happen live.
//
// Endpoints:
//
//	GET /            the dashboard page
//	GET /api/info    JSON: who served this request + all Pods seen recently + hit counter
//	GET /api/work    burns CPU for ?ms=N milliseconds (to trigger the autoscaler)
//	GET /healthz     liveness: the process is alive
//	GET /readyz      readiness: ready for traffic (fails while shutting down)
//	GET /metrics     Prometheus metrics
package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// Set at build time: go build -ldflags "-X main.version=v2"
var version = "dev"

//go:embed static/index.html
var static embed.FS

type config struct {
	port          string
	redisAddr     string
	color         string
	message       string
	podName       string
	nodeName      string
	namespace     string
	shutdownDelay time.Duration
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func loadConfig() config {
	host, _ := os.Hostname()
	delay, err := time.ParseDuration(env("SHUTDOWN_DELAY", "5s"))
	if err != nil {
		delay = 5 * time.Second
	}
	return config{
		port:          env("PORT", "8080"),
		redisAddr:     env("REDIS_ADDR", "localhost:6379"),
		color:         env("APP_COLOR", "#2563eb"),
		message:       env("APP_MESSAGE", "Hello from Kubernetes"),
		podName:       env("POD_NAME", host),
		nodeName:      env("NODE_NAME", "unknown"),
		namespace:     env("POD_NAMESPACE", "unknown"),
		shutdownDelay: delay,
	}
}

type server struct {
	cfg          config
	redis        *Redis
	shuttingDown atomic.Bool
	metrics      *metrics
}

type podInfo struct {
	Name     string `json:"name"`
	Version  string `json:"version"`
	Color    string `json:"color"`
	Node     string `json:"node"`
	Hits     int64  `json:"hits"`
	LastSeen int64  `json:"lastSeen"` // unix milliseconds
}

type infoResponse struct {
	Message   string    `json:"message"`
	Served    podInfo   `json:"servedBy"`
	Namespace string    `json:"namespace"`
	TotalHits int64     `json:"totalHits"`
	Redis     string    `json:"redis"` // "ok" or the error
	Pods      []podInfo `json:"pods"`  // Pods that served a request in the last few seconds
	Time      string    `json:"time"`
}

const (
	keyHits    = "pulse:hits"
	keyPods    = "pulse:pods"
	keyPodHits = "pulse:podhits"
	activeFor  = 6 * time.Second  // a Pod counts as "active" if it served within this window
	forgetFor  = 60 * time.Second // entries older than this are removed from Redis
)

func (s *server) handleInfo(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	self := podInfo{
		Name: s.cfg.podName, Version: version, Color: s.cfg.color,
		Node: s.cfg.nodeName, LastSeen: now.UnixMilli(),
	}
	resp := infoResponse{
		Message: s.cfg.message, Served: self, Namespace: s.cfg.namespace,
		Redis: "ok", Pods: []podInfo{}, Time: now.UTC().Format(time.RFC3339),
	}

	// Record this hit and read everyone else's. If Redis is down we still answer:
	// the page shows Redis as unavailable instead of the whole app failing.
	err := func() error {
		total, err := s.redis.Incr(keyHits)
		if err != nil {
			return err
		}
		resp.TotalHits = total
		if _, err := s.redis.HIncrBy(keyPodHits, s.cfg.podName, 1); err != nil {
			return err
		}
		meta, _ := json.Marshal(self)
		if err := s.redis.HSet(keyPods, s.cfg.podName, string(meta)); err != nil {
			return err
		}
		pods, err := s.redis.HGetAll(keyPods)
		if err != nil {
			return err
		}
		hits, err := s.redis.HGetAll(keyPodHits)
		if err != nil {
			return err
		}
		for name, raw := range pods {
			var p podInfo
			if json.Unmarshal([]byte(raw), &p) != nil {
				continue
			}
			age := now.Sub(time.UnixMilli(p.LastSeen))
			if age > forgetFor {
				_ = s.redis.HDel(keyPods, name)
				_ = s.redis.HDel(keyPodHits, name)
				continue
			}
			if age <= activeFor {
				p.Hits, _ = strconv.ParseInt(hits[name], 10, 64)
				resp.Pods = append(resp.Pods, p)
			}
		}
		return nil
	}()
	if err != nil {
		s.metrics.redisErrors.Add(1)
		resp.Redis = err.Error()
		resp.Pods = []podInfo{self}
	}
	sort.Slice(resp.Pods, func(i, j int) bool { return resp.Pods[i].Name < resp.Pods[j].Name })

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(resp)
}

// handleWork burns CPU, so the HorizontalPodAutoscaler has something to react to.
func (s *server) handleWork(w http.ResponseWriter, r *http.Request) {
	ms, err := strconv.Atoi(r.URL.Query().Get("ms"))
	if err != nil || ms <= 0 {
		ms = 50
	}
	if ms > 1000 {
		ms = 1000
	}
	deadline := time.Now().Add(time.Duration(ms) * time.Millisecond)
	x := 0
	for time.Now().Before(deadline) {
		for i := 0; i < 10000; i++ {
			x += i * i
		}
	}
	fmt.Fprintf(w, "worked %dms on %s (%d)\n", ms, s.cfg.podName, x%10)
}

func (s *server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	// Liveness: only "is this process able to answer at all?". Deliberately does NOT check
	// Redis - if Redis has a blip, restarting every app Pod would only make things worse.
	fmt.Fprintln(w, "ok")
}

func (s *server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	// Readiness: "send me traffic?". False while shutting down, so Kubernetes stops routing
	// new requests here before the process exits. Redis is NOT checked: the app degrades
	// gracefully without it, and failing readiness on every Pod at once would be an outage.
	if s.shuttingDown.Load() {
		http.Error(w, "shutting down", http.StatusServiceUnavailable)
		return
	}
	fmt.Fprintln(w, "ready")
}

func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	page, _ := static.ReadFile("static/index.html")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(page)
}

// ---- metrics (Prometheus text format, no library needed) ----

type metrics struct {
	mu          sync.Mutex
	requests    map[string]int64 // key: path|code
	redisErrors atomic.Int64
	inFlight    atomic.Int64
}

func (m *metrics) observe(path string, code int) {
	m.mu.Lock()
	m.requests[fmt.Sprintf("%s|%d", path, code)]++
	m.mu.Unlock()
}

func (s *server) handleMetrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintln(w, "# HELP pulse_info Build information.")
	fmt.Fprintln(w, "# TYPE pulse_info gauge")
	fmt.Fprintf(w, "pulse_info{version=%q,pod=%q} 1\n", version, s.cfg.podName)
	fmt.Fprintln(w, "# HELP pulse_http_requests_total HTTP requests by path and status code.")
	fmt.Fprintln(w, "# TYPE pulse_http_requests_total counter")
	s.metrics.mu.Lock()
	keys := make([]string, 0, len(s.metrics.requests))
	for k := range s.metrics.requests {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		var path string
		var code int
		for i := len(k) - 1; i >= 0; i-- {
			if k[i] == '|' {
				path, code = k[:i], atoiOr(k[i+1:], 0)
				break
			}
		}
		fmt.Fprintf(w, "pulse_http_requests_total{path=%q,code=\"%d\"} %d\n", path, code, s.metrics.requests[k])
	}
	s.metrics.mu.Unlock()
	fmt.Fprintln(w, "# HELP pulse_redis_errors_total Failed Redis operations.")
	fmt.Fprintln(w, "# TYPE pulse_redis_errors_total counter")
	fmt.Fprintf(w, "pulse_redis_errors_total %d\n", s.metrics.redisErrors.Load())
	fmt.Fprintln(w, "# HELP pulse_http_in_flight Requests currently being served.")
	fmt.Fprintln(w, "# TYPE pulse_http_in_flight gauge")
	fmt.Fprintf(w, "pulse_http_in_flight %d\n", s.metrics.inFlight.Load())
}

func atoiOr(s string, def int) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		return def
	}
	return n
}

type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.code = code
	r.ResponseWriter.WriteHeader(code)
}

// instrument wraps a handler to count requests (only for known paths, so random URLs
// can't blow up the number of metric series).
func (s *server) instrument(path string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s.metrics.inFlight.Add(1)
		defer s.metrics.inFlight.Add(-1)
		rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
		h(rec, r)
		s.metrics.observe(path, rec.code)
	}
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	cfg := loadConfig()
	s := &server{
		cfg:     cfg,
		redis:   NewRedis(cfg.redisAddr, 16),
		metrics: &metrics{requests: map[string]int64{}},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /", s.instrument("/", s.handleIndex))
	mux.HandleFunc("GET /api/info", s.instrument("/api/info", s.handleInfo))
	mux.HandleFunc("GET /api/work", s.instrument("/api/work", s.handleWork))
	mux.HandleFunc("GET /healthz", s.handleHealthz)
	mux.HandleFunc("GET /readyz", s.handleReadyz)
	mux.HandleFunc("GET /metrics", s.handleMetrics)

	srv := &http.Server{
		Addr:              ":" + cfg.port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		slog.Info("starting", "version", version, "port", cfg.port, "pod", cfg.podName, "redis", cfg.redisAddr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()

	// Graceful shutdown - the part that makes rolling updates truly zero-downtime:
	//  1. Kubernetes sends SIGTERM and, at the same time, starts removing this Pod from
	//     Service endpoints. That removal takes a moment to reach every node and the gateway.
	//  2. We fail /readyz and keep serving normally for SHUTDOWN_DELAY, so requests still
	//     routed here during that window succeed.
	//  3. Then we stop accepting connections and finish in-flight requests.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	sig := <-stop
	slog.Info("shutdown requested", "signal", sig.String(), "delay", cfg.shutdownDelay.String())
	s.shuttingDown.Store(true)
	time.Sleep(cfg.shutdownDelay)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		slog.Error("shutdown error", "err", err)
	}
	slog.Info("stopped cleanly")
}
