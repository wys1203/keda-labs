package controller

import "sync"

type NamespaceCache struct {
	mu    sync.RWMutex
	store map[string]map[string]string
}

func NewNamespaceCache() *NamespaceCache {
	return &NamespaceCache{store: make(map[string]map[string]string)}
}

func (c *NamespaceCache) Get(ns string) map[string]string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	src, ok := c.store[ns]
	if !ok {
		return nil
	}
	out := make(map[string]string, len(src))
	for k, v := range src {
		out[k] = v
	}
	return out
}

func (c *NamespaceCache) Put(ns string, labels map[string]string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	cp := make(map[string]string, len(labels))
	for k, v := range labels {
		cp[k] = v
	}
	c.store[ns] = cp
}

func (c *NamespaceCache) Delete(ns string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.store, ns)
}
