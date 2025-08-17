extends Node
var tasks = []  # сюда загрузим массив задач

func _ready():
	load_tasks()

func load_tasks():
	var file_path = "res://Data/tasks.json"
	if not FileAccess.file_exists(file_path):
		push_error("Tasks file not found: %s" % file_path)
		return
	# Читаем содержимое файла как текст
	var json_text = FileAccess.get_file_as_string(file_path)
	# Парсим JSON-текст в Variant (массив или словарь)
	var result = JSON.parse_string(json_text)
	if result == null:
		push_error("Ошибка разбора JSON данных задач")
	else:
		tasks = result  # т.к. в файле массив, result будет Array
		print("Loaded %d tasks" % tasks.size())
