package main

// A deliberately tiny Redis client (RESP protocol) using only the standard library,
// so the app has zero third-party dependencies. It supports exactly what Pulse needs.

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"time"
)

type Redis struct {
	addr        string
	dialTimeout time.Duration
	timeout     time.Duration
	pool        chan *redisConn
}

type redisConn struct {
	c net.Conn
	r *bufio.Reader
}

func NewRedis(addr string, poolSize int) *Redis {
	// Short timeouts on purpose: if Redis is unreachable, answer quickly without it
	// rather than making users wait.
	return &Redis{
		addr:        addr,
		dialTimeout: 300 * time.Millisecond,
		timeout:     700 * time.Millisecond,
		pool:        make(chan *redisConn, poolSize),
	}
}

func (r *Redis) get() (*redisConn, error) {
	select {
	case c := <-r.pool:
		return c, nil
	default:
		c, err := net.DialTimeout("tcp", r.addr, r.dialTimeout)
		if err != nil {
			return nil, err
		}
		return &redisConn{c: c, r: bufio.NewReader(c)}, nil
	}
}

func (r *Redis) put(c *redisConn) {
	select {
	case r.pool <- c:
	default:
		c.c.Close()
	}
}

// Do sends one command and returns the decoded reply:
// string (simple/bulk), int64, []any (array), or nil.
func (r *Redis) Do(args ...string) (any, error) {
	c, err := r.get()
	if err != nil {
		return nil, err
	}
	_ = c.c.SetDeadline(time.Now().Add(r.timeout))

	var b strings.Builder
	fmt.Fprintf(&b, "*%d\r\n", len(args))
	for _, a := range args {
		fmt.Fprintf(&b, "$%d\r\n%s\r\n", len(a), a)
	}
	if _, err := c.c.Write([]byte(b.String())); err != nil {
		c.c.Close()
		return nil, err
	}
	reply, err := readReply(c.r)
	if err != nil {
		var re redisError
		if errors.As(err, &re) {
			r.put(c) // a Redis error reply leaves the connection usable
		} else {
			c.c.Close()
		}
		return nil, err
	}
	r.put(c)
	return reply, nil
}

type redisError string

func (e redisError) Error() string { return "redis: " + string(e) }

func readReply(r *bufio.Reader) (any, error) {
	line, err := r.ReadString('\n')
	if err != nil {
		return nil, err
	}
	line = strings.TrimSuffix(line, "\r\n")
	if line == "" {
		return nil, errors.New("redis: empty reply")
	}
	switch line[0] {
	case '+':
		return line[1:], nil
	case '-':
		return nil, redisError(line[1:])
	case ':':
		return strconv.ParseInt(line[1:], 10, 64)
	case '$':
		n, err := strconv.Atoi(line[1:])
		if err != nil {
			return nil, err
		}
		if n < 0 {
			return nil, nil
		}
		buf := make([]byte, n+2)
		if _, err := io.ReadFull(r, buf); err != nil {
			return nil, err
		}
		return string(buf[:n]), nil
	case '*':
		n, err := strconv.Atoi(line[1:])
		if err != nil {
			return nil, err
		}
		if n < 0 {
			return nil, nil
		}
		out := make([]any, n)
		for i := range out {
			if out[i], err = readReply(r); err != nil {
				return nil, err
			}
		}
		return out, nil
	}
	return nil, fmt.Errorf("redis: unexpected reply %q", line)
}

// Helpers for the few commands Pulse uses.

func (r *Redis) Ping() error {
	_, err := r.Do("PING")
	return err
}

func (r *Redis) Incr(key string) (int64, error) {
	v, err := r.Do("INCR", key)
	if err != nil {
		return 0, err
	}
	n, _ := v.(int64)
	return n, nil
}

func (r *Redis) HIncrBy(key, field string, by int64) (int64, error) {
	v, err := r.Do("HINCRBY", key, field, strconv.FormatInt(by, 10))
	if err != nil {
		return 0, err
	}
	n, _ := v.(int64)
	return n, nil
}

func (r *Redis) HSet(key, field, value string) error {
	_, err := r.Do("HSET", key, field, value)
	return err
}

func (r *Redis) HDel(key, field string) error {
	_, err := r.Do("HDEL", key, field)
	return err
}

func (r *Redis) HGetAll(key string) (map[string]string, error) {
	v, err := r.Do("HGETALL", key)
	if err != nil {
		return nil, err
	}
	arr, _ := v.([]any)
	out := make(map[string]string, len(arr)/2)
	for i := 0; i+1 < len(arr); i += 2 {
		k, _ := arr[i].(string)
		val, _ := arr[i+1].(string)
		out[k] = val
	}
	return out, nil
}
