package webhook

import "github.com/wys1203/keda-labs/internal/rules"

// DiffByKey returns violations present in `new` whose key
// (RuleID, TriggerType, Field) is not present in `old`.
//
// TriggerIndex is intentionally NOT part of the key so that pure trigger
// reordering on UPDATE is not mis-classified as added violations.
//
// TriggerType IS part of the key so that swapping cpu→memory on the same
// trigger (still using metadata.type) is treated as a *new* memory-flavoured
// violation that didn't exist before — which is the desired strictness.
func DiffByKey(new, old []rules.Violation) []rules.Violation {
	type key struct{ RuleID, TriggerType, Field string }
	have := make(map[key]struct{}, len(old))
	for _, v := range old {
		have[key{v.RuleID, v.TriggerType, v.Field}] = struct{}{}
	}
	var added []rules.Violation
	for _, v := range new {
		if _, ok := have[key{v.RuleID, v.TriggerType, v.Field}]; !ok {
			added = append(added, v)
		}
	}
	return added
}
