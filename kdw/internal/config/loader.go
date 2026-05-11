package config

import (
	"fmt"

	"sigs.k8s.io/yaml"
)

// ParseYAML strictly unmarshals data into Config. Unknown fields are an
// error so typos in operator-managed CMs can't silently widen behaviour.
func ParseYAML(data []byte) (*Config, error) {
	var raw Config
	if err := yaml.UnmarshalStrict(data, &raw); err != nil {
		return nil, fmt.Errorf("parse yaml: %w", err)
	}
	if err := raw.Validate(); err != nil {
		return nil, err
	}
	return &raw, nil
}

func (c *Config) Validate() error {
	for i, r := range c.Rules {
		if r.ID == "" {
			return fmt.Errorf("rules[%d]: id is required", i)
		}
		if !validSeverity(r.DefaultSeverity) {
			return fmt.Errorf("rules[%d]: invalid defaultSeverity %q", i, r.DefaultSeverity)
		}
		for j, o := range r.NamespaceOverrides {
			if err := o.Validate(); err != nil {
				return fmt.Errorf("rules[%d].namespaceOverrides[%d]: %w", i, j, err)
			}
		}
	}
	return nil
}
