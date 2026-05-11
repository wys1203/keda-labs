package controller

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestNamespaceCache_GetMissing_ReturnsNil(t *testing.T) {
	c := NewNamespaceCache()
	assert.Nil(t, c.Get("nope"))
}

func TestNamespaceCache_PutThenGet_ReturnsCopy(t *testing.T) {
	c := NewNamespaceCache()
	c.Put("demo", map[string]string{"tier": "legacy"})

	got := c.Get("demo")
	assert.Equal(t, "legacy", got["tier"])

	// Mutating the returned map must NOT corrupt the cache.
	got["tier"] = "prod"
	assert.Equal(t, "legacy", c.Get("demo")["tier"])
}

func TestNamespaceCache_Delete(t *testing.T) {
	c := NewNamespaceCache()
	c.Put("demo", map[string]string{"a": "b"})
	c.Delete("demo")
	assert.Nil(t, c.Get("demo"))
}
