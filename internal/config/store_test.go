package config

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/wys1203/keda-labs/internal/rules"
)

func TestStore_DefaultLoad_ReturnsEmptyConfig(t *testing.T) {
	s := NewStore()
	cfg := s.Load()
	assert.NotNil(t, cfg)
	assert.Empty(t, cfg.Rules)
	assert.Equal(t, uint64(0), s.Generation())
}

func TestStore_StoreThenLoad_RoundTripsAndBumpsGeneration(t *testing.T) {
	s := NewStore()
	c := &Config{Rules: []RuleConfig{{ID: "KEDA001", DefaultSeverity: rules.SeverityError}}}
	s.Store(c)
	got := s.Load()
	assert.Equal(t, "KEDA001", got.Rules[0].ID)
	assert.Equal(t, uint64(1), s.Generation())
	s.Store(c)
	assert.Equal(t, uint64(2), s.Generation())
}
