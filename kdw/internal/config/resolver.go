package config

import "github.com/wys1203/keda-labs/kdw/internal/rules"

// EffectiveSeverity is called by both webhook handler and controller for
// every (ruleID, namespace) pair. Behaviour MUST stay identical between
// the two call sites — that's the whole point of having one function.
func (c *Config) EffectiveSeverity(ruleID, ns string, nsLabels map[string]string) rules.Severity {
	if rc, ok := c.findRule(ruleID); ok {
		for _, o := range rc.NamespaceOverrides {
			if o.matches(ns, nsLabels) {
				return o.Severity
			}
		}
		return rc.DefaultSeverity
	}
	return c.builtinDefault(ruleID)
}

func (c *Config) findRule(id string) (*RuleConfig, bool) {
	for i := range c.Rules {
		if c.Rules[i].ID == id {
			return &c.Rules[i], true
		}
	}
	return nil, false
}

func (c *Config) builtinDefault(id string) rules.Severity {
	for _, r := range rules.Registry {
		if r.ID() == id {
			return r.BuiltinDefaultSeverity()
		}
	}
	return rules.SeverityOff // unknown rule: be quiet
}
