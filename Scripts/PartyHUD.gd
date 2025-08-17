extends HBoxContainer

const CARD := preload("res://Scenes/HeroCard.tscn")
var cards: Array = []

func show_party(heroes: Array[Node2D]):
	# очистить старое
	for c in cards: c.queue_free()
	cards.clear()

	for h in heroes:
		var card = CARD.instantiate()
		add_child(card)
		card.bind(h)
		cards.append(card)
