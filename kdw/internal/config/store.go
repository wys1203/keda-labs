package config

import (
	"sync/atomic"
)

// Store holds the live Config in an atomic.Pointer so the webhook handler's
// hot path can do a lock-free Load() per admission request.
type Store struct {
	v   atomic.Pointer[Config]
	gen atomic.Uint64
}

func NewStore() *Store {
	s := &Store{}
	s.v.Store(&Config{}) // never return nil to callers
	return s
}

func (s *Store) Load() *Config {
	return s.v.Load()
}

func (s *Store) Store(c *Config) {
	s.v.Store(c)
	s.gen.Add(1)
}

func (s *Store) Generation() uint64 {
	return s.gen.Load()
}
