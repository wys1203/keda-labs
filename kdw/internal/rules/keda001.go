package rules

import "fmt"

type CpuMemoryMetadataType struct{}

func init() {
	Registry = append(Registry, &CpuMemoryMetadataType{})
}

func (*CpuMemoryMetadataType) ID() string                       { return "KEDA001" }
func (*CpuMemoryMetadataType) BuiltinDefaultSeverity() Severity { return SeverityError }

func (*CpuMemoryMetadataType) Lint(t Target) []Violation {
	var out []Violation
	for i, tr := range t.Triggers {
		if tr.Type != "cpu" && tr.Type != "memory" {
			continue
		}
		mdType, ok := tr.Metadata["type"]
		if !ok {
			continue
		}
		out = append(out, Violation{
			RuleID:       "KEDA001",
			TriggerIndex: i,
			TriggerType:  tr.Type,
			Field:        "metadata.type",
			Message: fmt.Sprintf(
				"trigger[%d] (type=%s): metadata.type is deprecated since KEDA 2.10 and removed in 2.18",
				i, tr.Type),
			FixHint: fmt.Sprintf(
				"Use triggers[%d].metricType: %s instead.", i, mdType),
		})
	}
	return out
}
