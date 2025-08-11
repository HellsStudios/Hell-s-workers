extends VBoxContainer


func _can_drop_data(position: Vector2, data: Variant) -> bool:
	# Позволяем сброс, только если перетаскивают задачу с таймлайна обратно.
	if typeof(data) != TYPE_DICTIONARY or not data.has("source"):
		return false
	if data["source"] != "timeline":
		return false
	# Можно добавить доп. проверки, например, data["node"] is ColorRect (TaskCard), но это и так.
	return true

func _drop_data(position: Vector2, data: Variant) -> void:
	if typeof(data) != TYPE_DICTIONARY or not data.has("node"):
		return
	var task_node = data["node"]
	# Возвращаем задачу в список:
	# Удалим с старого места (старый родитель) и добавим как child в VBoxContainer (нас)
	var old_parent = task_node.get_parent()
	if old_parent:
		old_parent.remove_child(task_node)
	add_child(task_node)
	# VBoxContainer сам расположит child в конце списка.
	# Можно, если нужно, вписать в определенное место - для простоты всегда вниз списка.
	# Сбросим свойства:
	task_node.schedule_start_slot = -1  # больше не на таймлайне
	# Можно уменьшить размер обратно, но контейнер все равно поправит ширину по своему.
	# Поставим видимость на true (хотя на таймлайне уже была true, но лишним не будет):
	task_node.visible = true
	# Вернем карточке исходный цвет (на случай, если меняли) - не обязательно.
	# Можно также сбросить флаги размера, чтобы опять растягивалась по списку:
	task_node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# (SIZE_EXPAND_FILL = Expand+Fill, обычно равен 3).
