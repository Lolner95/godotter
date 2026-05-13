@tool
extends RefCounted

## Client-side schema definitions and validation helpers.
## Mirrors the pydantic models in tools/godot_forge_agent/src/schemas.py.
## Used to validate and render plan responses in the UI.


static func validate_plan(data: Dictionary) -> Dictionary:
	var errors: Array = []
	if not data.has("summary"):
		errors.append("Missing: summary")
	if not data.has("steps"):
		errors.append("Missing: steps")
	return {"valid": errors.is_empty(), "errors": errors}


static func validate_visual_review_3d(data: Dictionary) -> Dictionary:
	var errors: Array = []
	for required in ["asset_path", "per_angle_findings", "overall_score", "priority_recommendations"]:
		if not data.has(required):
			errors.append("Missing: " + required)
	return {"valid": errors.is_empty(), "errors": errors}


static func validate_log_batch_fix_plan(data: Dictionary) -> Dictionary:
	var errors: Array = []
	for required in ["summary", "error_groups", "fix_steps"]:
		if not data.has(required):
			errors.append("Missing: " + required)
	return {"valid": errors.is_empty(), "errors": errors}


# --- Schema reference (for documentation / prompt building) ---

static func plan_schema() -> Dictionary:
	return {
		"summary": "str",
		"relevant_files": ["str"],
		"relevant_scenes": ["str"],
		"assumptions": ["str"],
		"risks": ["str"],
		"steps": [{
			"step_number": "int",
			"description": "str",
			"tool_calls": ["str"],
			"files_affected": ["str"],
			"risk_level": "low|medium|high",
		}],
		"validation_plan": ["str"],
		"approval_required": "bool",
	}


static func tool_call_schema() -> Dictionary:
	return {
		"tool_name": "str",
		"arguments": {},
		"reason": "str",
		"risk_level": "low|medium|high",
	}


static func visual_review_result_schema() -> Dictionary:
	return {
		"improved": "bool",
		"score_before": "int (0-10)",
		"score_after": "int (0-10)",
		"issues_found": ["str"],
		"evidence": ["str"],
		"recommended_next_fixes": ["str"],
		"confidence": "float (0.0-1.0)",
	}
