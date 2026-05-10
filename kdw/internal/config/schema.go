package config

import (
	"fmt"
	"path/filepath"

	"github.com/wys1203/keda-labs/kdw/internal/rules"
)

// Config is the parsed shape of the ConfigMap's `config.yaml` key.
type Config struct {
	Rules []RuleConfig `yaml:"rules" json:"rules"`
}

type RuleConfig struct {
	ID                 string              `yaml:"id"`
	DefaultSeverity    rules.Severity      `yaml:"defaultSeverity"`
	NamespaceOverrides []NamespaceOverride `yaml:"namespaceOverrides,omitempty"`
}

// NamespaceOverride matches a namespace by exact-or-glob name OR by label
// selector. Exactly one of `Names` or `LabelSelector` must be set.
type NamespaceOverride struct {
	Names         []string       `yaml:"names,omitempty"`
	LabelSelector *LabelSelector `yaml:"labelSelector,omitempty"`
	Severity      rules.Severity `yaml:"severity"`
}

type LabelSelector struct {
	MatchLabels      map[string]string  `yaml:"matchLabels,omitempty"`
	MatchExpressions []LabelRequirement `yaml:"matchExpressions,omitempty"`
}

type LabelRequirement struct {
	Key      string   `yaml:"key"`
	Operator string   `yaml:"operator"` // "In" | "NotIn" | "Exists" | "DoesNotExist"
	Values   []string `yaml:"values,omitempty"`
}

func (o *NamespaceOverride) Validate() error {
	switch {
	case len(o.Names) > 0 && o.LabelSelector != nil:
		return fmt.Errorf("namespaceOverrides entry must have exactly one of `names` or `labelSelector`, not both")
	case len(o.Names) == 0 && o.LabelSelector == nil:
		return fmt.Errorf("namespaceOverrides entry must have one of `names` or `labelSelector`")
	}
	if !validSeverity(o.Severity) {
		return fmt.Errorf("invalid severity %q (want error|warn|off)", o.Severity)
	}
	if o.LabelSelector != nil {
		for _, e := range o.LabelSelector.MatchExpressions {
			switch e.Operator {
			case "In", "NotIn", "Exists", "DoesNotExist":
			default:
				return fmt.Errorf("invalid matchExpressions operator %q", e.Operator)
			}
		}
	}
	return nil
}

func validSeverity(s rules.Severity) bool {
	switch s {
	case rules.SeverityError, rules.SeverityWarn, rules.SeverityOff:
		return true
	}
	return false
}

func (o *NamespaceOverride) matches(ns string, nsLabels map[string]string) bool {
	if len(o.Names) > 0 {
		for _, pat := range o.Names {
			if ok, _ := filepath.Match(pat, ns); ok {
				return true
			}
		}
		return false
	}
	if o.LabelSelector != nil {
		return labelSelectorMatches(o.LabelSelector, nsLabels)
	}
	return false
}

func labelSelectorMatches(sel *LabelSelector, labels map[string]string) bool {
	for k, v := range sel.MatchLabels {
		if labels[k] != v {
			return false
		}
	}
	for _, e := range sel.MatchExpressions {
		val, present := labels[e.Key]
		switch e.Operator {
		case "Exists":
			if !present {
				return false
			}
		case "DoesNotExist":
			if present {
				return false
			}
		case "In":
			if !present || !contains(e.Values, val) {
				return false
			}
		case "NotIn":
			if present && contains(e.Values, val) {
				return false
			}
		}
	}
	return true
}

func contains(haystack []string, needle string) bool {
	for _, h := range haystack {
		if h == needle {
			return true
		}
	}
	return false
}
