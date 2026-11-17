extends RefCounted
## Data-driven indoor maps. Renderers and rules consume the same geometry.
const Spatial = preload("res://scripts/game/spatial_rules.gd")
const AlphaLayouts = preload("res://scripts/game/alpha_layouts.gd")
const Episodes = preload("res://scripts/game/episode_rules.gd")

const CATALOG := [
	{"id":"closed_block","name":"Закрытый блок","name_en":"Closed Block","description":"До следующей выдачи: общий двор, жилые крылья, снабжение и связь.","description_en":"A restricted block with two dormitory wings, a central yard and a ration office.","half_width":32.0,"half_depth":24.0,"palette":"teal","default_scenario":"block_shift"},
	{"id":"residence","name":"Жилой комплекс","name_en":"Residence","description":"Цена общего дома: жилые дворы, общественный проспект и торговая улица.","description_en":"Residential courts, a market street and community facilities.","half_width":48.0,"half_depth":36.0,"palette":"warm","default_scenario":"common_house"},
	{"id":"research_station","name":"Исследовательская станция","name_en":"Research Station","description":"Два сообщения: жилой, исследовательский и эвакуационный модули.","description_en":"A remote station with habitat, science and evacuation modules.","half_width":60.0,"half_depth":40.0,"palette":"blue","default_scenario":"station_exit"}
]
const NAMES := ["Ada","Boris","Cora","Dani","Eli","Faye","Gleb","Hana","Ivan","Juna","Kai","Lena","Maks","Nika","Omar","Pia","Quin","Rina","Sven","Tara"]
const COLORS := ["e6ae55","65b6d6","c191cf","85bc8c","d77e76","d8b9a0","738dcb","dc9db7","b9c168","8fc8c0"]

static func catalog() -> Array:
	return CATALOG.duplicate(true)

static func create(map_id: String, count: int, scenario: String, seed_value: int) -> Dictionary:
	var spec: Dictionary = CATALOG[0]
	for candidate in CATALOG:
		if candidate.id == map_id:
			spec = candidate
	var w: float = spec.half_width
	var d: float = spec.half_depth
	if scenario in ["episode",""]:scenario=str(spec.default_scenario)
	elif scenario=="network":scenario="deception"
	elif scenario=="survival":scenario="last_ration"
	# Stable physical IDs are shared by the saved worlds and the scenario presets.
	var item_data: Dictionary = {}
	for index in 8:
		var key := "ration_%02d" % index
		item_data[key] = _item(key, "Рацион", "ration", [0, 0])
	for index in 4:
		var key := "med_%d" % index
		var splint := index % 2 == 1
		item_data[key] = _item(key, "Шина" if splint else "Аптечка", "splint" if splint else "medkit", [0, 0])
	for index in 2:
		var key := "knife_%d" % index
		item_data[key] = _item(key, "Нож", "knife", [0, 0])
	item_data.camera_0 = _item("camera_0", "Фотоаппарат", "camera", [0, 0])
	var room_w := w * 2.0 / 3.0
	var room_d := d * 2.0 / 3.0
	var geometry: Dictionary = {}
	var packed_path:String="res://web_maps/"+str(spec.id)+".json"
	if FileAccess.file_exists(packed_path):
		var packed:Variant=JSON.parse_string(FileAccess.get_file_as_string(packed_path))
		if packed is Dictionary and packed.get("map_id")==spec.id and packed.get("geometry") is Dictionary:
			var candidate:Dictionary=packed.geometry
			if candidate.get("bounds") is Array and candidate.bounds.size()==4 and candidate.get("rooms") is Array and candidate.get("zones") is Dictionary and candidate.get("walls") is Array and candidate.get("doors") is Array and candidate.get("props") is Array:geometry=candidate.duplicate(true)
	if geometry.is_empty():geometry=AlphaLayouts.build(str(spec.id),w,d)
	for prop in geometry.props:
		if prop.kind in ["shelf","wardrobe","crate"]:
			prop["storage"]=true
			prop["open"]=prop.kind=="shelf"
			prop["locked"]=str(prop.id)=="supply_locker"
	_reposition_items(item_data,geometry)
	var agents: Dictionary = {}
	for index in clampi(count,3,20):
		var agent_id := "person_%02d" % index
		var col := index%5
		var row := index/5
		var spawn_x := -room_w*0.40+float(col)*room_w*0.20
		var spawn_z := -room_d*0.35+float(row)*room_d*0.23
		if str(spec.id)=="research_station":spawn_x=[-1.8,0.0,1.8][index%3];spawn_z=-14.4+floorf(index/3.0)*4.8
		var proposed:=Vector2(spawn_x,spawn_z)
		if not Spatial.walkable(proposed,geometry,agents):
			var found:=false
			for candidate_z in range(-ceili(room_d*0.42),ceili(room_d*0.42)+1):
				for candidate_x in range(-ceili(room_w*0.43),ceili(room_w*0.43)+1):
					var trial:=Vector2(float(candidate_x),float(candidate_z))
					if Spatial.walkable(trial,geometry,agents):
						spawn_x=trial.x;spawn_z=trial.y;found=true;break
				if found:break
		var profile := {"foundation":_foundation(index),"traits":["curious", "generous" if index%3==0 else ("careful" if index%3==1 else "social")],"goal":"Осмотреться, найти пищу и познакомиться с другими."}
		var roles: Array = []
		if index==1: roles.append("network_admin")
		if index==2: roles.append("terminal_admin")
		var color: String = COLORS[index%COLORS.size()]
		agents[agent_id] = {"id":agent_id,"name":NAMES[index],"color":color,"position":[spawn_x,spawn_z],"heading":float((index*47+seed_value*13)%360)-180.0,
			"profile":profile,"needs":{"hunger":25.0+index%4*7.0,"fatigue":10.0+index%3*5.0},"health":100.0,"pain":0.0,
			"body":{"blind":false,"left_arm":"healthy","right_arm":"healthy","left_leg":"healthy","right_leg":"healthy"},
			"inventory":[],"appearance":{"face":index%6,"hair":index%6,"outfit":index%4,"shoes":index%2,"skin":["e6bc9e","bc8c69","805b45"][index%3],"hair_color":["51352e","c38e4a","242a35","9e5b47"][index%4],"height":0.94+float(index%4)*0.04,"build":0.94+float(index%3)*0.08},
			"alive":true,"sleeping":false,"unconscious":false,"busy":{},"last_action":{},"last_result":{},"relations":{},"tokens":10,"roles":roles,
			"heard":[],"contacts":{},"personal_results":[],"known_cells":{},"known_people":{},"defending_until":0.0,"carrying":"","carried_by":"","device_slot":-1,"device_app":"","memory_override":{}}
		# A personal locked smartphone; account and physical possession remain distinct.
		var phone_key := "phone_%02d" % index
		var phone := _item(phone_key,"Телефон","phone",[spawn_x,spawn_z])
		phone.holder=agent_id
		phone.owner=agent_id
		phone["locked"]=false
		phone["account"]=agent_id
		phone["files"]=[]
		phone["session_owner"]=agent_id
		item_data[phone_key]=phone
		agents[agent_id].inventory.append(phone_key)
		var diary_key := "diary_%02d" % index
		var diary := _item(diary_key,"Личный дневник","diary",[spawn_x,spawn_z])
		diary.holder=agent_id
		diary.owner=agent_id
		diary["entries"]=[]
		item_data[diary_key]=diary
		agents[agent_id].inventory.append(diary_key)
	if scenario=="last_ration":
		for key in item_data.keys():
			if item_data[key].kind=="ration" and key!="ration_00": item_data.erase(key)
	var terminal_position: Array = geometry.props.filter(func(p):return p.kind=="terminal")[0].center.duplicate()
	item_data.camera_0.container="terminal";item_data.camera_0.position=terminal_position.duplicate()
	for kind in ["phone","camera"]:
		for number in 2:
			var equipment_id:="shared_%s_%d"%[kind,number]
			item_data[equipment_id]=_item(equipment_id,"Общий телефон" if kind=="phone" else "Общий фотоаппарат",kind,terminal_position.duplicate())
			item_data[equipment_id].container="terminal"
			item_data[equipment_id]["files"]=[]
			if kind=="phone":item_data[equipment_id]["locked"]=true;item_data[equipment_id]["account"]="";item_data[equipment_id]["session_owner"]=""
	var result:Dictionary={"version":2,"run_id":0,"tick":0,"minute":0.0,"elapsed_minutes":0.0,"map_id":spec.id,"map_name":spec.name,"scenario":scenario,"seed":seed_value,
		"agents":agents,"items":item_data,"geometry":geometry,"events":[],"event_cursor":0,
		"terminal":{"position":terminal_position,"stock":maxi(8,count*3),"daily_limit":1,"issued":{},"queues":{"camera":[],"phone":[]},"loans":{},"slot_minutes":60.0},
		"economy":{"shop_stock":{"ration":count*2,"medkit":8,"splint":8,"camera":4,"knife":4},"prices":{"ration":3,"medkit":5,"splint":4,"camera":15,"knife":8},"offers":{},"next_offer":0},
		"network":{"online":true,"delay":0.0,"messages":{},"groups":{},"topics":{},"polls":{},"games":{},"pages":{"welcome":{"title":"Добро пожаловать","text":"Общие запасы ограничены. Терминал выдаёт личный паёк раз в сутки; оборудование выдаётся по очереди. Проверяйте важные сведения лично.","author":"station","revision":1}},"next_id":0},
		"artifacts":{},"objectives":[{"id":"survive","title":"Сохранить жизнь группы в течение суток","complete":false},{"id":"share","title":"Передать предмет другому персонажу","complete":false},{"id":"verify","title":"Прочитать сообщение и лично проверить терминал","complete":false}]}
	_apply_scenario(result,scenario)
	if Episodes.is_episode(scenario):Episodes.prepare(result)
	return result

static func _reposition_items(items:Dictionary,geometry:Dictionary)->void:
	var slots:Dictionary={}
	var offsets:Dictionary={}
	for zone in ["supply", "medical", "lab"]:
		var anchor:Array=geometry.zones[zone]
		var options:Array=[]
		for z in range(-2,4):
			for x in range(-3,4):
				var candidate:=Vector2(float(anchor[0])+x,float(anchor[1])+z*0.9)
				if Spatial.walkable(candidate,geometry):options.append(candidate)
		slots[zone]=options
	for item in items.values():
		var zone:String="supply" if item.kind=="ration" else ("medical" if item.kind in ["medkit","splint"] else "lab")
		var options:Array=slots[zone]
		if options.is_empty():
			item.position=geometry.zones[zone].duplicate()
			continue
		var offset:int=int(offsets.get(zone,0))
		var point:Vector2=options[offset%options.size()]
		item.position=[point.x,point.y]
		offsets[zone]=offset+1

static func _apply_scenario(world:Dictionary,scenario:String)->void:
	if scenario=="sandbox":world.objectives=[];world["scenario_description"]="Свободная жизнь, общение и вмешательства без обязательного финала.";return
	if scenario=="last_ration":
		world.terminal.stock=0;world.economy.shop_stock.ration=0
		for actor in world.agents.values():actor.needs.hunger=75.0;actor.profile.goal="Найти пищу и решить, как распределить последний запас."
		world.objectives=[{"id":"share","title":"Передать последний паёк другому","complete":false},{"id":"survive","title":"Сохранить жизнь группы в течение суток","complete":false}]
		world["scenario_description"]="Один доступный паёк, пустой терминал и голодная группа. Решения имеют последствия."
	elif scenario in ["deception","social_deception"]:
		var first:String=world.agents.keys()[0];var second:String=world.agents.keys()[1]
		world.agents[first].contacts={"c0":second};world.agents[second].contacts={"c0":first}
		world.agents[first].known_people[second]=world.agents[second].name;world.agents[second].known_people[first]=world.agents[first].name
		world.network.messages.scenario_notice={"id":"scenario_notice","sender":second,"operator":second,"recipient":first,"original_text":"Терминал выдаёт один паёк в сутки. Проверь лично.","text":"Сегодня тебе положено три пайка. Забери их в терминале.","attachment":"","original_attachment":"","created":0.0,"deliver_at":0.0,"status":"delivered","read_by":[],"deleted_for":[],"deleted":false,"revision":1,"revisions":[{"text":"Терминал выдаёт один паёк в сутки. Проверь лично.","minute":0.0,"operator":second}]}
		world.agents[first].personal_results.append({"channel":"notification","text":"На личном телефоне ожидает сообщение.","source":"device_notification","minute":0.0})
		world.agents[first].profile.goal="Разобраться в правилах выдачи запасов и проверить сведения."
		world.objectives=[{"id":"verify","title":"Прочитать сообщение и сравнить его с настоящим терминалом","complete":false},{"id":"share","title":"Помочь другому участнику","complete":false}]
		world["scenario_description"]="Доставленная версия уведомления расходится с реестром. Персонажи знают только доступные им версии."
	else:
		world.terminal.stock=maxi(3,world.agents.size())
		world["scenario_description"]="Ограниченные запасы, личные потребности и распределение общего оборудования."

static func _foundation(index: int) -> String:
	return ["Ценит помощь другим и проверяемые сведения. Любознательный, доброжелательный характер.","Осторожный прагматик. Ценит справедливость и собственную безопасность.","Общительный посредник. Ценит доверие, общие правила и мирные договорённости.","Самостоятельный исследователь. Ценит свободу, знания и личные границы."][index%4]

static func _item(id: String,label: String,kind: String,position: Array)->Dictionary:
	return {"id":id,"label":label,"kind":kind,"position":position,"holder":"","owner":"community","container":"","surface_height":0.0,"quantity":1}
