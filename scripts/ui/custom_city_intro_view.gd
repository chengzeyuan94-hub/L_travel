extends Control
## Editor preview wraps the exact production FormalCityCard; it never paints another card skin.
const FORMAL := preload("res://scenes/ui/components/formal_city_card.tscn")
var formal_card: FormalCityCard
var title_label: Label
var description_label: Label
var image_view: TextureRect
func _ready() -> void: build()
func build() -> void:
 if formal_card != null: return
 mouse_filter = Control.MOUSE_FILTER_PASS
 formal_card = FORMAL.instantiate(); formal_card.show_user_intro = true; add_child(formal_card)
 formal_card.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
 resized.connect(_fit_card)
 _fit_card()
func _fit_card() -> void:
 if formal_card == null: return
 var fit := minf(size.x / FormalCityCard.DESIGN_SIZE.x, size.y / FormalCityCard.DESIGN_SIZE.y)
 formal_card.size = FormalCityCard.DESIGN_SIZE * maxf(fit, 0.001)
 formal_card.position = (size - formal_card.size) * 0.5
func bind_card(card: Dictionary, city_name: String, pending: Dictionary = {}, city_id: String = "") -> void:
 build()
 var content: Dictionary = GameState.content
 if city_id == "":
  for cid in content.get("cities", {}):
   if str(content.cities[cid].get("display_name", "")) == city_name: city_id = str(cid); break
 var resolved := FormalCardPresentationResolver.resolve_city_card(content, city_id).duplicate(true)
 resolved["user_intro"] = card.duplicate(true)
 var texture: Texture2D = ImageTexture.create_from_image(pending.image) if not pending.is_empty() else null
 formal_card.bind_resolved(resolved, content, texture)
 title_label = formal_card._title; description_label = formal_card._intro_body; image_view = formal_card._art
 _fit_card()
func description_text() -> String: return formal_card.user_description_text()
func description_line_count() -> int:
 var count := 0
 for label: Label in [formal_card._intro_body, formal_card._scenery_body]:
  if not label.text.is_empty(): count += label.get_line_count()
 return count
