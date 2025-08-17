extends Button

var _task_index: int = -1          # внутреннее поле

var task_index: int:
	set(value):
		_task_index = value

		var data = TaskManager.tasks[value]         # <<< исправили
		$Label.text = data.get("qualification",
							   "Задача %d" % value)
	get:
		return _task_index
