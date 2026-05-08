package webhook

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/wys1203/keda-labs/internal/rules"
)

func TestDiffByKey_NewViolation_IsAdded(t *testing.T) {
	old := []rules.Violation{}
	new := []rules.Violation{
		{RuleID: "KEDA001", TriggerType: "cpu", Field: "metadata.type"},
	}
	got := DiffByKey(new, old)
	assert.Len(t, got, 1)
}

func TestDiffByKey_SameViolationOnUpdate_NotAdded(t *testing.T) {
	v := rules.Violation{RuleID: "KEDA001", TriggerType: "cpu", Field: "metadata.type"}
	got := DiffByKey([]rules.Violation{v}, []rules.Violation{v})
	assert.Empty(t, got)
}

// Pure trigger-reorder must NOT look like a new violation (per spec amendment).
func TestDiffByKey_TriggerReorder_NotAdded(t *testing.T) {
	oldV := []rules.Violation{
		{RuleID: "KEDA001", TriggerIndex: 0, TriggerType: "cpu", Field: "metadata.type"},
		{RuleID: "KEDA001", TriggerIndex: 1, TriggerType: "memory", Field: "metadata.type"},
	}
	newV := []rules.Violation{
		{RuleID: "KEDA001", TriggerIndex: 0, TriggerType: "memory", Field: "metadata.type"},
		{RuleID: "KEDA001", TriggerIndex: 1, TriggerType: "cpu", Field: "metadata.type"},
	}
	got := DiffByKey(newV, oldV)
	assert.Empty(t, got)
}

func TestDiffByKey_ChangingTriggerTypeOnSameIndex_IsAdded(t *testing.T) {
	oldV := []rules.Violation{}
	newV := []rules.Violation{
		{RuleID: "KEDA001", TriggerIndex: 0, TriggerType: "memory", Field: "metadata.type"},
	}
	got := DiffByKey(newV, oldV)
	assert.Len(t, got, 1)
}
