@tool
extends RefCounted

## In-memory task queue for the plugin side.
## Tasks are created here when commands are submitted,
## then synced with the backend SQLite store via AgentClient.

signal task_added(task: Dictionary)
signal task_updated(task_id: String, task: Dictionary)
signal task_removed(task_id: String)

var _tasks: Dictionary = {}  # task_id -> task dict
var _counter: int = 0

const VALID_STATUSES := [
	"queued", "gathering_context", "planning", "waiting_for_approval",
	"editing", "running_project", "capturing_screenshot", "validating",
	"reviewing", "complete", "failed", "blocked", "reverted",
]


func add_task(title: String, user_request: String, priority: int = 1) -> Dictionary:
	_counter += 1
	var task_id := "task_%04d_%d" % [_counter, Time.get_unix_time_from_system()]
	var task := {
		"id": task_id,
		"title": title,
		"user_request": user_request,
		"created_at": Time.get_unix_time_from_system(),
		"status": "queued",
		"priority": priority,
		"current_step": 0,
		"plan": {},
		"subtasks": [],
		"context_bundle": {},
		"files_to_inspect": [],
		"files_modified": [],
		"scenes_modified": [],
		"screenshots": [],
		"validation_results": [],
		"logs": [],
		"final_report": {},
		"approval_required": true,
		"retry_count": 0,
		"parent_task_id": "",
	}
	_tasks[task_id] = task
	task_added.emit(task)
	return task


func update_status(task_id: String, status: String) -> void:
	if not _tasks.has(task_id):
		return
	if status not in VALID_STATUSES:
		push_warning("[TaskQueue] Invalid status: " + status)
		return
	_tasks[task_id]["status"] = status
	task_updated.emit(task_id, _tasks[task_id])


func update_task(task_id: String, patch: Dictionary) -> void:
	if not _tasks.has(task_id):
		return
	if patch.has("status"):
		var next_status: String = str(patch.get("status", ""))
		if next_status not in VALID_STATUSES:
			push_warning("[TaskQueue] Invalid status in update_task: " + next_status)
			return
	for key in patch:
		_tasks[task_id][key] = patch[key]
	task_updated.emit(task_id, _tasks[task_id])


func remove_task(task_id: String) -> void:
	if _tasks.has(task_id):
		_tasks.erase(task_id)
		task_removed.emit(task_id)


func get_task(task_id: String) -> Dictionary:
	return _tasks.get(task_id, {})


func get_all_tasks() -> Array:
	var result := _tasks.values()
	result.sort_custom(func(a, b): return a.get("created_at", 0) > b.get("created_at", 0))
	return result


func get_tasks_by_status(status: String) -> Array:
	var result: Array = []
	for task in _tasks.values():
		if task.get("status", "") == status:
			result.append(task)
	return result


func cancel_task(task_id: String) -> void:
	update_status(task_id, "failed")


func clear_completed() -> void:
	var to_remove: Array = []
	for task_id in _tasks:
		if _tasks[task_id].get("status", "") in ["complete", "reverted"]:
			to_remove.append(task_id)
	for task_id in to_remove:
		remove_task(task_id)
