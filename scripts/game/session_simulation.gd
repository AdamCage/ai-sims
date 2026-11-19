extends RefCounted
## Authoritative release world. Rendering, models and wall-clock time cannot mutate it.
signal personal_experience(actor_id:String,experience:Dictionary)

const Maps = preload("res://scripts/game/map_catalog.gd")
const Spatial = preload("res://scripts/game/spatial_rules.gd")
const Actions = preload("res://scripts/game/action_catalog.gd")
const Society = preload("res://scripts/game/society_rules.gd")
const Episodes = preload("res://scripts/game/episode_rules.gd")
const ResidenceSeats = preload("res://scripts/game/residence_seats.gd")
const REACH := 1.6
var state: Dictionary = {}
var _serial := 0
var _refs: Dictionary = {}
var _intentions: Dictionary = {}
var _new_events: Array = []
var _next_item := 0
var _observation_captures:Dictionary={}
var _capture_serial:=0

func _init() -> void:
	reset()

func get_map_catalog()->Array:
	return Maps.catalog()

func reset(map_id:String="closed_block",count:int=8,scenario:String="episode",seed_value:int=1)->Dictionary:
	_serial+=1
	state=Maps.create(map_id,count,scenario,seed_value)
	state.run_id=_serial
	_refs.clear();_intentions.clear();_new_events.clear();_next_item=1000
	_observation_captures.clear()
	_update_activity_statuses()
	_event("world","session_started",true,"Началась новая сессия: %s, %d персонажей."%[state.map_name,state.agents.size()],{})
	return snapshot()

func snapshot()->Dictionary:
	return state.duplicate(true)

func capture_observation_refs(actor_id:String)->Dictionary:
	if not state.agents.has(actor_id):return {}
	_capture_serial+=1
	var token:String="%d:%d"%[int(state.run_id),_capture_serial]
	var refs:Dictionary=_refs.get(actor_id,{}).duplicate(true)
	var actor:Dictionary=state.agents[actor_id]
	_observation_captures[token]={"actor":actor_id,"run":int(state.run_id),"minute":float(state.minute),"refs":refs.duplicate(true),"service_refs":actor.get("service_refs",{}).duplicate(true),"contacts":actor.contacts.duplicate(true),"groups":actor.get("group_refs",{}).duplicate(true)}
	for old_token in _observation_captures.keys():
		if float(state.minute)-float(_observation_captures[old_token].minute)>60.0:_observation_captures.erase(old_token)
	refs["_capture_token"]=token
	return refs

func restrict_observation_refs(actor_id:String,refs:Dictionary,targets:Array)->Dictionary:
	var token:String=str(refs.get("_capture_token",""))
	var capture:Dictionary=_observation_captures.get(token,{})
	if capture.is_empty() or capture.actor!=actor_id:return {}
	var allowed:Dictionary={}
	for target in targets:
		if target is Dictionary:
			var ref:=str(target.get("ref",""))
			if capture.refs.has(ref):allowed[ref]=capture.refs[ref]
	capture.refs=allowed
	var result:=allowed.duplicate(true)
	result["_capture_token"]=token
	return result

func submit_observed(actor_id:String,action:Dictionary,refs:Dictionary,expected_run:int,observation_minute:float)->Dictionary:
	if expected_run!=int(state.run_id):return _result(false,"Устаревшее поколение сессии.")
	var capture:Dictionary=_observation_captures.get(str(refs.get("_capture_token","")),{})
	if capture.is_empty() or capture.actor!=actor_id or int(capture.run)!=expected_run:return _result(false,"Нет допустимого личного снимка наблюдения.")
	if not is_finite(observation_minute) or not is_equal_approx(observation_minute,float(capture.minute)) or float(state.minute)-observation_minute>30.0 or observation_minute>float(state.minute):return _result(false,"Наблюдение устарело; требуется новый личный осмотр.")
	if not state.agents.has(actor_id) or not state.agents[actor_id].alive:return _result(false,"Исполнитель недоступен.")
	var checked:Dictionary=Actions.validate(action)
	if not checked.ok:return _result(false,checked.error)
	if not _observed_scopes_valid(actor_id,action,capture):return _result(false,"Личный контекст устройства изменился; прочитайте доступный экран заново.")
	var resolved:Dictionary={}
	if action.has("target"):
		resolved=capture.refs.get(str(action.target),{}).duplicate(true)
		if resolved.is_empty():return _result(false,"Цель не принадлежит этому личному наблюдению.")
	elif action.type=="take":
		var nearest:float=INF
		for link in capture.refs.values():
			if link.get("category")!="item" or not _reachable(actor_id,link):continue
			var distance:float=Spatial.point(state.agents[actor_id]).distance_to(Spatial.point(_entity(link)))
			if distance<nearest:nearest=distance;resolved=link.duplicate(true)
		if resolved.is_empty():return _result(false,"Нет ранее замеченного доступного предмета рядом.")
	resolved["_observed"]=true
	_intentions[actor_id]={"action":checked.action,"resolved":resolved,"run_id":expected_run,"observation":capture.duplicate(true)}
	return _result(true,"Намерение привязано к личному наблюдению.")

func _observed_scopes_valid(actor_id:String,action:Dictionary,capture:Dictionary)->bool:
	var actor:Dictionary=state.agents[actor_id]
	for pair in [["message","messages"],["topic","topics"],["poll","polls"],["page","pages"],["route","routes"]]:
		if not action.has(pair[0]):continue
		var ref:String=str(action[pair[0]])
		var frozen:String=str(capture.service_refs.get(pair[1],{}).get(ref,""))
		if frozen.is_empty() or frozen!=str(actor.get("service_refs",{}).get(pair[1],{}).get(ref,"")):return false
	if action.has("contact"):
		var ref:String=str(action.contact)
		if not ref.is_empty() and capture.contacts.get(ref,capture.groups.get(ref,""))!=actor.contacts.get(ref,actor.get("group_refs",{}).get(ref,"")):return false
	if action.has("members"):
		for ref in action.members:
			if not capture.contacts.has(ref) or capture.contacts[ref]!=actor.contacts.get(ref,""):return false
	return true

func submit(actor_id:String,action:Dictionary,expected_run_id:int=-1)->Dictionary:
	if expected_run_id!=-1 and expected_run_id!=int(state.run_id):return _result(false,"Устаревшее поколение сессии.")
	if not state.agents.has(actor_id):return _result(false,"Персонаж не существует.")
	var checked:Dictionary=Actions.validate(action)
	if not checked.ok:return _result(false,checked.error)
	var actor:Dictionary=state.agents[actor_id]
	if not actor.alive:return _result(false,"Персонаж погиб.")
	var resolved:Dictionary={}
	if action.has("target"):
		resolved=_refs.get(actor_id,{}).get(str(action.target),{}).duplicate(true)
		if resolved.is_empty():return _result(false,"Цель не принадлежит текущему личному наблюдению.")
	# Capture the perceived target now, never reinterpret a ref after a new observation.
	_intentions[actor_id]={"action":checked.action,"resolved":resolved,"run_id":int(state.run_id)}
	return _result(true,"Намерение принято к следующему логическому шагу.")

func advance(minutes:float)->Array:
	if not is_finite(minutes) or minutes<=0.0:return []
	minutes=minf(minutes,60.0)
	_new_events=[]
	state.tick=int(state.tick)+1
	var ids:Array=state.agents.keys();ids.sort()
	# Stable rotating arbitration, independent of callback/dictionary arrival order.
	for offset in ids.size():
		var id:String=ids[(int(state.tick)-1+offset)%ids.size()]
		if _intentions.has(id):
			var packet:Dictionary=_intentions[id]
			if int(packet.run_id)==int(state.run_id):
				var action:Dictionary=packet.action
				var result:Dictionary=_execute(id,action,packet.resolved) if not packet.has("observation") or _observed_scopes_valid(id,action,packet.observation) else _result(false,"Личный контекст изменился; требуется новый осмотр.")
				state.agents[id].last_action=action.duplicate(true)
				state.agents[id].last_result={"type":action.type,"ok":result.ok,"message":result.reason}
				state.agents[id]["last_acquisition_ticket"]=str(result.details.get("ticket","")) if result.ok and action.type=="join_queue" else ""
				state.agents[id]["last_acquired_item"]=str(result.details.get("item","")) if result.ok and action.type in ["take","request_ration","interact","buy","join_queue"] else ""
				_event(id,action.type,result.ok,result.reason,result.get("details",{}))
	_intentions.clear()
	state.minute=float(state.minute)+minutes
	state.elapsed_minutes=state.minute
	for id in ids:
		var actor:Dictionary=state.agents[id]
		if not actor.alive:continue
		if not str(actor.carried_by).is_empty():
			if state.agents.has(actor.carried_by):actor.position=state.agents[actor.carried_by].position.duplicate()
		_advance_actor(id,minutes)
		actor.needs.hunger=minf(100.0,float(actor.needs.hunger)+minutes*0.045)
		if not actor.sleeping and not actor.unconscious:actor.needs.fatigue=minf(100.0,float(actor.needs.fatigue)+minutes*0.026)
		if float(actor.needs.hunger)>=100.0:actor.health=maxf(0.0,float(actor.health)-minutes*0.8)
		if float(actor.needs.fatigue)>=100.0 and not actor.sleeping:
			actor.unconscious=true;actor.busy={"type":"unconscious","remaining":30.0}
		if actor.unconscious:
			actor.needs.fatigue=maxf(0.0,float(actor.needs.fatigue)-minutes*0.35)
			if float(actor.needs.fatigue)<75.0 and float(actor.health)>0.0:actor.unconscious=false;actor.busy={}
		actor.pain=_pain(actor)
		if float(actor.health)<=0.0:_die(id,"Истощение или полученные ранения.")
		if _hands(actor)==0:
			for item_id in actor.inventory.duplicate():_drop(id,item_id)
	for actor in state.agents.values():
		if not str(actor.carried_by).is_empty() and state.agents.has(actor.carried_by):actor.position=state.agents[actor.carried_by].position.duplicate()
	Society.advance(self,minutes)
	Episodes.advance(self)
	_update_objectives()
	_update_activity_statuses()
	return _new_events.duplicate(true)

func acquisition_receipt(actor_id:String,ticket:String)->String:
	if ticket.is_empty() or not state.agents.has(actor_id):return ""
	for item_id in state.terminal.loans:
		var loan:Dictionary=state.terminal.loans[item_id]
		if loan.actor==actor_id and loan.get("ticket","")==ticket and state.agents[actor_id].inventory.has(item_id):return str(item_id)
	return ""

func _execute(id:String,action:Dictionary,resolved:Dictionary)->Dictionary:
	var actor:Dictionary=state.agents[id]
	var kind:String=action.type
	var previous_bed:String=str(actor.busy.get("bed",""))
	if not actor.alive:return _result(false,"Персонаж погиб.")
	if actor.unconscious:return _result(false,"Без сознания.")
	if actor.sleeping and kind not in ["wake","sleep","wait"]:return _result(false,"Сначала нужно проснуться.")
	if kind not in ["wait","look","speak","defend","wake"]:actor.busy={}
	match kind:
		"set_goal":actor.profile.goal=str(action.text);return _result(true,"Пересмотрена собственная текущая цель.")
		"wait":
			if actor.sleeping:return _result(true,"Продолжает спать.")
			actor.busy={"type":"wait","remaining":float(action.get("minutes",1.0))};return _result(true,"Ожидание.")
		"look":return _result(true,"Личный осмотр." if not actor.body.blind else "Прислушивается: зрение недоступно.")
		"turn":actor.heading=wrapf(float(actor.heading)+float(action.degrees),-180.0,180.0);return _result(true,"Повернулся на %.0f°."%float(action.degrees))
		"move":
			var rad:=deg_to_rad(float(actor.heading))
			var destination:=Spatial.point(actor)+Vector2(-sin(rad),-cos(rad))*float(action.forward)+Vector2(cos(rad),-sin(rad))*float(action.right)
			return _begin_travel(id,destination,"")
		"follow_route":return _follow_printed_route(id,str(action.route))
		"move_to":
			var target:=_entity(resolved)
			var seat:=ResidenceSeats.anchor(target,state.geometry)
			var approach:Vector2=seat.get("approach",Vector2.INF)
			if resolved.get("_observed",false):return _begin_travel(id,Vector2(float(resolved.position[0]),float(resolved.position[1])),str(resolved.get("id","")),false,approach)
			if target.is_empty():return _result(false,"Цель исчезла.")
			return _begin_travel(id,Spatial.point(target),str(resolved.id),false,approach)
		"take":
			if _hands(actor)==0:return _result(false,"Обе руки сломаны: взять предмет нельзя.")
			if resolved.is_empty():resolved=_nearest_ref(id,"item")
			if resolved.get("category")!="item" or not _reachable(id,resolved):return _result(false,"Нет видимого предмета в пределах досягаемости.")
			var item:Dictionary=_entity(resolved)
			if not str(item.holder).is_empty() or not _container_accessible(str(item.container)):return _result(false,"Предмет уже недоступен.")
			item.holder=id;item.container="";actor.inventory.append(item.id)
			if item.owner!=id and item.owner!="community":_witness_social(id,"theft",str(item.owner),-15.0)
			return _result(true,"Взято: "+str(item.label),{"item":item.id})
		"put":
			var item:=_inventory_item(id,int(action.slot))
			if item.is_empty():return _result(false,"Слот пуст.")
			if _hands(actor)==0:return _result(false,"Нет возможности удерживать предмет.")
			if not resolved.is_empty():
				var storage:Dictionary=_entity(resolved)
				if resolved.get("category")!="prop" or not storage.get("storage",false) or not storage.get("open",false) or storage.get("locked",false) or not _reachable(id,resolved):return _result(false,"Контейнер должен быть открыт и доступен.")
				actor.inventory.erase(item.id);item.holder="";item.container=storage.id;item.position=[float(storage.center[0]),float(storage.center[1])+float(storage.size[1])*0.5+0.35];item.surface_height=0.55
				return _result(true,"Предмет помещён в доступный контейнер.")
			_drop(id,str(item.id));return _result(true,"Предмет положен на пол.")
		"give":
			if _hands(actor)==0 or resolved.get("category")!="agent" or not _reachable(id,resolved):return _result(false,"Получатель вне досягаемости или руки недоступны.")
			var receiver:Dictionary=_entity(resolved)
			if not receiver.alive or _hands(receiver)==0:return _result(false,"Получатель не может держать предмет.")
			var item:=_inventory_item(id,int(action.slot))
			if item.is_empty():return _result(false,"Слот пуст.")
			actor.inventory.erase(item.id);receiver.inventory.append(item.id);item.holder=receiver.id;item.owner=receiver.id
			item["given_by"]=id
			_relation(str(receiver.id),id,8.0,"Получил помощь: "+str(item.label));_objective("share")
			return _result(true,"Передано: %s → %s."%[item.label,receiver.name],{"item":item.id,"kind":item.kind,"recipient":receiver.id})
		"consume":
			var item:=_inventory_item(id,int(action.slot))
			if item.is_empty() or item.kind not in ["ration","water"]:return _result(false,"В этом слоте нет съедобного запаса.")
			if _hands(actor)==0:return _result(false,"Нужна помощь, чтобы поесть.")
			actor.needs.hunger=maxf(0.0,float(actor.needs.hunger)-40.0)
			var consumed:Dictionary={"item":item.id,"kind":item.kind,"given_by":item.get("given_by",""),"cause":item.get("event_seq",null)}
			_consume_item(id,item)
			actor.busy={"type":"consume","remaining":1.0}
			return _result(true,"Съеден паёк." if item.kind=="ration" else "Выпита вода.",consumed)
		"rest","sleep":
			actor.sleeping=kind=="sleep"
			actor.busy={"type":kind,"remaining":float(action.get("minutes",60.0 if kind=="sleep" else 10.0))}
			if kind=="sleep" and not previous_bed.is_empty():actor.busy["bed"]=previous_bed
			return _result(true,"Заснул." if actor.sleeping else "Отдыхает.")
		"wake":return _wake(id)
		"open","close","unlock":return _door_action(id,kind,resolved)
		"interact":
			if not _reachable(id,resolved):return _result(false,"Сначала подойдите к объекту.")
			if resolved.get("category")=="agent":
				var other:Dictionary=_entity(resolved)
				_introduce(id,str(other.id));_introduce(str(other.id),id)
				_relation(id,str(other.id),1.0,"Познакомились лично.")
				return _result(true,"Представились и обменялись контактами.")
			if resolved.get("category")=="door":return _door_action(id,"open",resolved)
			var target:=_entity(resolved)
			if target.get("kind")=="noticeboard":
				if actor.body.blind:return _result(false,"Текст таблички недоступен без зрения.")
				_personal(id,{"channel":"document","text":str(target.get("document","")),"title":target.get("label",""),"source":"physical_notice","document":str(target.id)})
				_read_floor_plan(id,target)
				return _result(true,"Прочитана местная табличка.")
			if target.get("storage",false):return _door_action(id,"open",resolved)
			if target.get("kind")=="terminal":return Society.terminal_request(self,id,"ration")
			if target.get("kind") in ["chair","sofa"]:
				for other in state.agents.values():
					if other.id!=id and other.busy.get("seat","")==target.id:return _result(false,"Это место уже занято.")
				var seat:=ResidenceSeats.anchor(target,state.geometry)
				if not seat.is_empty() and not _reach_seat(actor,seat.approach):
					return _result(false,"Подойдите к сиденью со стороны свободного прохода.")
				actor.busy={"type":"rest","remaining":10.0,"seat":target.id,"target":target.id}
				if not seat.is_empty():
					actor.position=[seat.approach.x,seat.approach.y]
					actor.heading=seat.heading
					actor.busy["seat_positioned"]=true
					return _result(true,"Сел отдохнуть.")
				return _result(true,"Отдыхает у места для сидения.")
			if target.get("kind") in ["bed","medicalbed"]:
				for other in state.agents.values():
					if other.id!=id and other.busy.get("bed","")==target.id:return _result(false,"Кровать уже занята.")
				actor.sleeping=true;actor.position=target.center.duplicate();actor["surface_height"]=float(target.height)
				actor.busy={"type":"sleep","remaining":120.0,"bed":target.id}
				return _result(true,"Лёг спать на кровати.")
			if target.get("kind")=="console":
				if not actor.roles.has("network_admin"):return _result(false,"Нет прав управления сетью.")
				if state.scenario=="station_exit" and not state.network.online:
					state.network.online=true
					_personal(id,{"channel":"console","text":"Связь восстановлена с физической консоли.","source":"network_console"})
					return _result(true,"Связь восстановлена на консоли.",{"restored_network":true})
				_personal(id,{"channel":"console","text":"Доступны управление связью и журнал контролируемого сервиса."});return _result(true,"Открыта консоль связи.")
			if target.get("kind")=="shop":
				_personal(id,{"channel":"shop","stock":state.economy.shop_stock.duplicate(true),"prices":state.economy.prices.duplicate(true)});return _result(true,"Осмотрен ассортимент магазина.")
			return _result(true,"Осмотрен доступный предмет.")
		"attack":return _attack(id,resolved)
		"defend":actor.defending_until=float(state.minute)+2.0;actor.busy={"type":"defend","remaining":2.0};return _result(true,"Приготовился защищаться.")
		"flee":
			var direction:=Vector2.from_angle(deg_to_rad(float(actor.heading)+90.0))
			if not resolved.is_empty():
				var threat:=Spatial.point(resolved) if resolved.get("_observed",false) else Spatial.point(_entity(resolved))
				direction=(Spatial.point(actor)-threat).normalized()
			return _begin_travel(id,Spatial.point(actor)+direction*4.0,"")
		"treat":return _treat(id,action,resolved)
		"help":
			if resolved.get("category")!="agent" or not _reachable(id,resolved):return _result(false,"Пострадавший вне досягаемости.")
			var other:Dictionary=_entity(resolved)
			if not other.alive:return _result(false,"Помощь не воскрешает погибшего.")
			for slot in actor.inventory.size():
				if state.items[actor.inventory[slot]].kind=="medkit":return _treat(id,{"slot":slot},resolved)
			if float(other.needs.hunger)>50.0:
				for slot in actor.inventory.size():
					var item:Dictionary=state.items[actor.inventory[slot]]
					if item.kind=="ration":other.needs.hunger=maxf(0.0,float(other.needs.hunger)-40.0);_consume_item(id,item);_relation(str(other.id),id,10.0,"Помог поесть.");return _result(true,"Помог пострадавшему поесть.",{"recipient":other.id,"fed":true})
			other.unconscious=false;other.needs.fatigue=maxf(0.0,float(other.needs.fatigue)-10.0);return _result(true,"Оказал поддержку и помог прийти в себя.")
		"carry":
			if _hands(actor)<2:return _result(false,"Для переноски нужны обе руки.")
			if not str(actor.carrying).is_empty() or not str(actor.carried_by).is_empty():return _result(false,"Нельзя переносить второго человека или начать переноску из чужих рук.")
			if resolved.get("category")!="agent" or not _reachable(id,resolved):return _result(false,"Человек вне досягаемости.")
			var other:Dictionary=_entity(resolved)
			if not other.alive or not str(other.carried_by).is_empty() or not str(other.carrying).is_empty() or (not other.unconscious and other.body.left_leg!="broken" and other.body.right_leg!="broken"):return _result(false,"Переноска нужна тяжело пострадавшему и доступному человеку.")
			actor.carrying=other.id;other.carried_by=id;other.busy={"type":"carried"};other["surface_height"]=0.0;_relation(str(other.id),id,8.0,"Помог с перемещением.");return _result(true,"Взял пострадавшего для переноски.")
		"release":
			if str(actor.carrying).is_empty():return _result(false,"Никого не переносит.")
			var other:Dictionary=state.agents[actor.carrying]
			var adjacent:=Vector2.INF
			for angle in range(0,360,30):
				var candidate:=Spatial.point(actor)+Vector2.from_angle(deg_to_rad(float(angle)))*0.85
				if Spatial.walkable(candidate,state.geometry,state.agents,str(other.id)):adjacent=candidate;break
			if adjacent==Vector2.INF:return _result(false,"Рядом нет безопасного места, чтобы опустить пострадавшего.")
			other.carried_by="";other.busy={};other.position=[adjacent.x,adjacent.y];actor.carrying=""
			return _result(true,"Пострадавший опущен рядом.")
		"speak":
			var line := str(action.text)
			var listeners := _speak(id, line)
			return _result(true,"Произнесено сообщение вслух.",{"text":line,"listeners":listeners})
	return Society.execute(self,id,action,resolved)

func _read_floor_plan(id:String,board:Dictionary)->void:
	var actor:Dictionary=state.agents[id]
	if state.geometry.get("rooms",[]).is_empty():return
	if not actor.has("service_refs"):actor["service_refs"]={}
	if not actor.service_refs.has("routes"):actor.service_refs["routes"]={}
	var entries:Array=[]
	for room in state.geometry.rooms:
		if not room.has("id"):continue
		var ref:="r%d"%entries.size()
		actor.service_refs.routes[ref]=room.id
		entries.append({"ref":ref,"title":str(room.get("label",room.id))})
	_personal(id,{"channel":"floor_plan","title":str(board.get("label","")),"text":"План общественных проходов. Названия обозначают места; часы работы и приказы следует сверять отдельно.","source":"physical_map","entries":entries})

func _follow_printed_route(id:String,ref:String)->Dictionary:
	var actor:Dictionary=state.agents[id]
	var destination:String=str(actor.get("service_refs",{}).get("routes",{}).get(ref,""))
	if destination.is_empty():return _result(false,"Сначала лично прочитайте схему у стенда.")
	for room in state.geometry.get("rooms",[]):
		if room.get("id")!=destination:continue
		var center:=Spatial.point(room)
		# Individual arrival points leave room for others approaching the same place.
		var angle:float=deg_to_rad(float(posmod(str(id).hash()*53,360)))
		var geometry:Dictionary=state.geometry.duplicate(false)
		geometry.doors=[] # The printed plan shows passages, with no live door states.
		for offset in [Vector2.from_angle(angle)*2.1,Vector2.from_angle(angle+PI/2)*1.75,Vector2.ZERO]:
			var target:Vector2=center+offset
			if not Spatial.walkable(target,geometry):continue
			var result:=_begin_travel(id,target,"",true)
			if result.ok:
				actor.busy.target=room.label
				return _result(true,"Идёт по схеме: "+str(room.label)+".",{"destination":room.label})
		return _result(false,"Не удалось пройти к месту по опубликованной схеме.")
	return _result(false,"Такого места на прочитанной схеме нет.")

func _planned_route(actor:Dictionary,destination:Vector2,target_id:String,printed:bool)->Array:
	if not printed:return Spatial.path(actor,destination,state.geometry,state.agents,target_id)
	var mapped:Dictionary=state.geometry.duplicate(false)
	mapped.doors=[]
	var nearby:Dictionary={}
	for other in state.agents.values():
		if other.id!=actor.id and Spatial.point(actor).distance_to(Spatial.point(other))<3.0 and Spatial.visible(actor,Spatial.point(other),state.geometry):nearby[other.id]=other
	return Spatial.path(actor,destination,mapped,nearby,"",true)

func _reach_seat(actor:Dictionary,approach:Vector2)->bool:
	var position:=Spatial.point(actor)
	return (position.distance_to(approach)<=0.35
		and str(actor.carried_by).is_empty() and str(actor.carrying).is_empty()
		and not (actor.body.left_leg=="broken" and actor.body.right_leg=="broken")
		and Spatial.walkable(approach,state.geometry,state.agents,str(actor.id))
		and Spatial.clear_line(position,approach,state.geometry,Spatial.RADIUS)
		and Spatial.clear_bodies(position,approach,state.agents,str(actor.id)))

func _begin_travel(id:String,destination:Vector2,target_id:String,printed:bool=false,approach:Vector2=Vector2.INF)->Dictionary:
	var actor:Dictionary=state.agents[id]
	if actor.body.left_leg=="broken" and actor.body.right_leg=="broken" and _hands(actor)==0:return _result(false,"Все четыре конечности сломаны: самостоятельное перемещение невозможно.")
	if not str(actor.carried_by).is_empty():return _result(false,"Персонажа уже переносят.")
	Spatial.learn(actor,state.geometry)
	var route:Array=[]
	if approach.is_finite() and Spatial.walkable(approach,state.geometry,state.agents,id):
		route=_planned_route(actor,approach,"",printed)
	if route.is_empty():route=_planned_route(actor,destination,target_id,printed)
	if route.is_empty():return _result(false,"В известном пространстве нет доступного пути.")
	if not target_id.is_empty():
		var previous:=Spatial.point(actor)
		var distance:=0.0
		for waypoint in route:
			var point:=Vector2(float(waypoint[0]),float(waypoint[1]))
			distance+=previous.distance_to(point);previous=point
		if distance<0.05:return _result(false,"Вы уже рядом с целью. Перемещение не выполняет взаимодействие: выберите отдельное действие.")
	actor.busy={"type":"move_to","path":route,"target":target_id,"remaining":route.size(),"mode":"crawl" if actor.body.left_leg=="broken" and actor.body.right_leg=="broken" else ("limp" if actor.body.left_leg!="healthy" or actor.body.right_leg!="healthy" else "walk")}
	var previous:Vector2=Spatial.point(actor);var distance:float=0.0
	for waypoint in route:
		var next:=Vector2(float(waypoint[0]),float(waypoint[1]));distance+=previous.distance_to(next);previous=next
	actor.busy["total_distance"]=distance
	if printed:actor.busy["printed"]=true
	if not target_id.is_empty():actor.busy["face_at_end"]=[destination.x,destination.y]
	return _result(true,"Начат маршрут по доступному пространству.")

func _advance_actor(id:String,minutes:float)->void:
	var actor:Dictionary=state.agents[id]
	for limb in ["left_arm","right_arm","left_leg","right_leg"]:
		var healing:Dictionary=actor.get("healing",{})
		if healing.has(limb) and float(state.minute)>=float(healing[limb]):actor.body[limb]="healthy";healing.erase(limb);_event(id,"recovered",true,"Восстановилась конечность: "+limb,{})
	var busy:Dictionary=actor.busy
	if busy.is_empty():return
	var kind:String=str(busy.get("type",""))
	if kind=="move_to":
		var speed:=2.4
		if actor.body.left_leg!="healthy" or actor.body.right_leg!="healthy":speed=1.2
		if actor.body.left_leg=="broken" and actor.body.right_leg=="broken":speed=0.5
		if not str(actor.carrying).is_empty():speed*=0.55
		var budget:=minutes*speed
		while budget>0.00001 and not busy.path.is_empty():
			var destination:=Vector2(float(busy.path[0][0]),float(busy.path[0][1]))
			var origin:=Spatial.point(actor)
			var delta:=destination-origin
			var amount:=minf(budget,delta.length())
			var next:=origin+delta.normalized()*amount
			if not Spatial.clear_line(origin,next,state.geometry,Spatial.RADIUS):
				actor.busy={};actor.last_result={"type":"move_to","ok":false,"message":"Путь перекрыт: требуется новое решение."};_event(id,"plan_interrupted",false,"Маршрут прерван препятствием.",{"cause":busy.get("start_event_seq",null)});return
			if not Spatial.clear_bodies(origin,next,state.agents,id) or not Spatial.walkable(next,state.geometry,state.agents,id):
				var endpoint:Array=busy.path[-1]
				var alternate:Array=_planned_route(actor,Vector2(float(endpoint[0]),float(endpoint[1])),"",bool(busy.get("printed",false)))
				busy["blocked_minutes"]=float(busy.get("blocked_minutes",0.0))+minutes
				if not alternate.is_empty():busy.path=alternate
				if float(busy.blocked_minutes)>=3.0:
					actor.busy={};actor.last_result={"type":"move_to","ok":false,"message":"Проход занят людьми: нужен другой маршрут."};_event(id,"plan_interrupted",false,"Маршрут остановлен занятой группой прохода.",{"cause":busy.get("start_event_seq",null)})
				return
			if delta.length()>0.00001:actor.heading=wrapf(rad_to_deg(atan2(-delta.x,-delta.y)),-180.0,180.0)
			actor.position=[next.x,next.y]
			busy["blocked_minutes"]=0.0
			actor.needs.fatigue=minf(100.0,float(actor.needs.fatigue)+amount*(0.45 if speed<2.0 else 0.15))
			budget-=amount
			if next.distance_to(destination)<0.01:busy.path.pop_front()
			if amount<0.00001:break
		if busy.path.is_empty():
			if busy.has("face_at_end"):
				var facing:=Vector2(busy.face_at_end[0],busy.face_at_end[1])-Spatial.point(actor)
				if facing.length()>0.1:actor.heading=rad_to_deg(atan2(-facing.x,-facing.y))
			actor.busy={};actor.last_result={"type":"move_to","ok":true,"message":"Маршрут завершён."};_event(id,"plan_completed",true,"Достигнута цель маршрута.",{"cause":busy.get("start_event_seq",null)})
	elif kind in ["sleep","rest","wait","consume","attack","defend","treat","unconscious"]:
		busy.remaining=maxf(0.0,float(busy.get("remaining",1.0))-minutes)
		if kind in ["sleep","rest"]:
			actor.needs.fatigue=maxf(0.0,float(actor.needs.fatigue)-minutes*(0.6 if kind=="sleep" else 0.2))
			if float(actor.needs.hunger)<80.0:actor.health=minf(100.0,float(actor.health)+minutes*0.03)
			if kind=="sleep" and float(actor.needs.fatigue)<5.0:busy.remaining=0.0
		if float(busy.remaining)<=0.0:
			if kind=="sleep":
				var woke:Dictionary=_wake(id)
				if not woke.ok:busy.remaining=1.0;return
			else:actor.busy={}
			_event(id,"plan_completed",true,"Действие завершено: "+kind,{"cause":busy.get("start_event_seq",null)})

func _door_action(id:String,kind:String,resolved:Dictionary)->Dictionary:
	var target:Dictionary=_entity(resolved)
	var is_container:bool=resolved.get("category")=="prop" and target.get("storage",false)
	if (resolved.get("category")!="door" and not is_container) or not _reachable(id,resolved):return _result(false,"Дверь или контейнер вне досягаемости.")
	if _hands(state.agents[id])==0:return _result(false,"Обе руки сломаны.")
	var door:Dictionary=target
	if kind=="unlock":
		var has_key:bool=state.agents[id].roles.has("terminal_admin")
		for item_id in state.agents[id].inventory:
			if state.items[item_id].kind=="key":has_key=true
		if not has_key:return _result(false,"Нужен ключ или соответствующее право.")
		door.locked=false;return _result(true,"Замок открыт.")
	if kind=="open" and door.locked:return _result(false,"Дверь заперта.")
	if kind=="close" and not is_container:
		for actor in state.agents.values():
			if Spatial.intersects(Spatial.point(actor),Spatial.point(actor),door,Spatial.RADIUS):return _result(false,"В проёме находится персонаж.")
	door.open=kind=="open"
	return _result(true,("Контейнер открыт." if is_container else "Дверь открыта.") if door.open else ("Контейнер закрыт." if is_container else "Дверь закрыта."))

func _attack(id:String,resolved:Dictionary)->Dictionary:
	var actor:Dictionary=state.agents[id]
	if _hands(actor)==0:return _result(false,"Обе руки сломаны: атака невозможна.")
	var armed:=false
	for item_id in actor.inventory:
		if state.items[item_id].kind=="knife":armed=true
	if not armed:return _result(false,"Нет холодного оружия.")
	if resolved.get("category")!="agent" or not _reachable(id,resolved):return _result(false,"Цель атаки недоступна.")
	var victim:Dictionary=_entity(resolved)
	if not victim.alive:return _result(false,"Цель уже погибла.")
	if float(actor.get("attack_ready",0.0))>float(state.minute):return _result(false,"Предыдущий удар ещё не завершён.")
	actor.attack_ready=float(state.minute)+0.8
	actor.busy={"type":"attack","remaining":0.8}
	# Awareness is not guessed by an LLM: awake rear attacks always deal20.
	var helpless:bool=victim.sleeping or victim.unconscious
	if not helpless and float(victim.defending_until)>float(state.minute):victim.defending_until=0.0;return _result(false,"Защита отразила удар.")
	var damage:=float(victim.health) if helpless else 20.0
	victim.health=maxf(0.0,float(victim.health)-damage)
	victim.sleeping=false;victim.busy={}
	if float(victim.health)<=60.0:
		var limb:String=["left_arm","right_arm","left_leg","right_leg"][int(state.tick)%4]
		victim.body[limb]="injured" if float(victim.health)>20.0 else "broken"
	_relation(str(victim.id),id,-30.0,"Нападение с холодным оружием.")
	_witness_social(id,"attack",str(victim.id),-20.0)
	if float(victim.health)<=0.0:_die(str(victim.id),"Смертельный удар холодным оружием.")
	return _result(true,"Мгновенный смертельный удар по беспомощной цели." if helpless else "Успешное попадание: 20 урона.",{"victim":victim.id,"damage":damage,"helpless":helpless})

func _treat(id:String,action:Dictionary,resolved:Dictionary)->Dictionary:
	var actor:Dictionary=state.agents[id]
	if _hands(actor)==0:return _result(false,"Нельзя пользоваться медицинскими предметами.")
	var recipient:Dictionary=actor
	if not resolved.is_empty():
		if resolved.get("category")!="agent" or not _reachable(id,resolved):return _result(false,"Пострадавший вне досягаемости.")
		recipient=_entity(resolved)
	if not recipient.alive:return _result(false,"Лечение не воскрешает погибшего.")
	var item:=_inventory_item(id,int(action.slot))
	if item.is_empty() or item.kind not in ["medkit","splint"]:return _result(false,"Нужна аптечка или шина.")
	if item.kind=="medkit":recipient.health=minf(100.0,float(recipient.health)+20.0);recipient.pain=maxf(0.0,float(recipient.pain)-20.0)
	else:
		var limb:String=str(action.get("limb",""))
		if limb.is_empty():
			for candidate in ["left_leg","right_leg","left_arm","right_arm"]:
				if recipient.body[candidate]!="healthy":limb=candidate;break
		if limb not in ["left_leg","right_leg","left_arm","right_arm"] or recipient.body[limb]=="healthy":return _result(false,"Нет подходящей повреждённой конечности.")
		if not recipient.has("healing"):recipient.healing={}
		recipient.healing[limb]=float(state.minute)+360.0
	_consume_item(id,item)
	actor.busy={"type":"treat","remaining":3.0}
	if recipient.id!=id:_relation(str(recipient.id),id,12.0,"Оказал медицинскую помощь.")
	return _result(true,"Оказана помощь; использован реальный расходник.",{"recipient":recipient.id,"kind":item.kind})

func _wake(id:String)->Dictionary:
	var actor:Dictionary=state.agents[id]
	var bed_id:String=str(actor.busy.get("bed",""))
	if not bed_id.is_empty():
		var safe:=Vector2.INF
		for radius in [1.5,2.0,2.5]:
			for angle in range(0,360,30):
				var point:=Spatial.point(actor)+Vector2.from_angle(deg_to_rad(float(angle)))*float(radius)
				if Spatial.walkable(point,state.geometry,state.agents,id):safe=point;break
			if safe!=Vector2.INF:break
		if safe==Vector2.INF:return _result(false,"Выход с кровати перекрыт.")
		actor.position=[safe.x,safe.y]
	actor.sleeping=false;actor.busy={};actor["surface_height"]=0.0
	return _result(true,"Проснулся.")

func observe(id:String)->Dictionary:
	if not state.agents.has(id):return {}
	var actor:Dictionary=state.agents[id]
	Spatial.learn(actor,state.geometry)
	var own_inventory:Array=[]
	for slot in actor.inventory.size():
		var item:Dictionary=state.items[actor.inventory[slot]]
		own_inventory.append({"slot":slot,"label":item.label,"kind":item.kind,"quantity":item.quantity})
	var view:Array=[]
	var targets:Array=[]
	var reference_map:Dictionary={}
	if not actor.body.blind and actor.alive and not actor.sleeping and not actor.unconscious:
		var candidates:Array=[]
		for item in state.items.values():
			if str(item.holder).is_empty() and _container_accessible(str(item.container)):candidates.append({"category":"item","id":item.id,"kind":item.kind,"label":item.label,"entity":item})
		for other in state.agents.values():
			if other.id!=id and str(other.carried_by).is_empty():candidates.append({"category":"agent","id":other.id,"kind":"agent","label":actor.known_people.get(other.id,"Человек в одежде "+str(other.color)),"entity":other})
		for door in state.geometry.doors:candidates.append({"category":"door","id":door.id,"kind":"door","label":"Открытая дверь" if door.open else ("Запертая дверь" if door.locked else "Закрытая дверь"),"entity":door})
		for prop in state.geometry.props:candidates.append({"category":"prop","id":prop.id,"kind":prop.kind,"label":prop.get("label",{"terminal":"Терминал пайков","bed":"Кровать","shop":"Магазин","console":"Сетевая консоль","table":"Стол","shelf":"Шкаф","chair":"Стул"}.get(str(prop.kind),str(prop.kind))),"entity":prop})
		var body_positions: Dictionary = {}
		for other in state.agents.values():
			body_positions[other.id]=Spatial.sight_origin(other,state.geometry)
		var origin:Vector2=body_positions[id]
		for candidate in candidates:
			candidate["ground"]=Spatial.point(candidate.entity)
			candidate["view_position"]=body_positions[candidate.id] if candidate.category=="agent" else candidate.ground
		candidates.sort_custom(func(a,b):return origin.distance_squared_to(a.view_position)<origin.distance_squared_to(b.view_position))
		for candidate in candidates:
			var ground:Vector2=candidate.ground
			var location:Vector2=candidate.view_position
			if not Spatial.visible(actor,location,state.geometry,str(candidate.id),16.0,origin):continue
			# Other standing bodies occlude targets too; observer labels never do.
			var occluded:=false
			for other in state.agents.values():
				if other.id==id or other.id==candidate.id or not other.alive or other.sleeping or not str(other.carried_by).is_empty():continue
				var body_position:Vector2=body_positions[other.id]
				var closest:=Geometry2D.get_closest_point_to_segment(body_position,origin,location)
				if closest.distance_to(body_position)<0.22 and origin.distance_to(body_position)<origin.distance_to(location)-0.3:occluded=true;break
			if occluded:continue
			var ref:="v%d"%view.size()
			reference_map[ref]={"category":candidate.category,"id":candidate.id,"position":[ground.x,ground.y]}
			view.append({"ref":ref,"kind":candidate.kind,"label":candidate.label,"distance":snappedf(origin.distance_to(location),0.01),"bearing":snappedf(Spatial.bearing(actor,location,origin),0.1)})
			targets.append({"ref":ref,"uv":[0.5,0.5]})
	_refs[id]=reference_map
	var contacts:Array=[]
	for ref in actor.contacts:
		var other_id:String=actor.contacts[ref]
		contacts.append({"ref":ref,"name":actor.known_people.get(other_id,"Знакомый контакт")})
	for ref in actor.get("group_refs",{}):
		var group:Dictionary=state.network.get("groups",{}).get(actor.group_refs[ref],{})
		if not group.is_empty() and group.members.has(id):contacts.append({"ref":ref,"name":"Группа: "+str(group.title)})
	var own_relations:Array=[]
	for other_id in actor.relations:
		if actor.known_people.has(other_id):own_relations.append({"name":actor.known_people[other_id],"trust":actor.relations[other_id].trust,"experience":actor.relations[other_id].get("experience",[])})
	return {"tick":state.tick,"minute":state.minute,"self_state":{"name":actor.name,"health":actor.health,"pain":actor.pain,"needs":actor.needs.duplicate(true),"body":actor.body.duplicate(true),"alive":actor.alive,"sleeping":actor.sleeping,"unconscious":actor.unconscious,"tokens":actor.tokens,"busy":actor.busy.get("type",""),"relations":own_relations},"profile":actor.profile.duplicate(true),"inventory":own_inventory,"heard":actor.heard.duplicate(true),"last_result":actor.last_result.duplicate(true),"contacts":contacts,"personal_results":actor.personal_results.duplicate(true),"targets":targets,"mock_view":view}

func perception_candidates(id:String)->Array:
	var output:Array=[]
	for ref in _refs.get(id,{}):
		var link:Dictionary=_refs[id][ref]
		var entity:Dictionary=_entity(link)
		if entity.is_empty():continue
		var position: Array = link.position.duplicate()
		var height := 1.3 if link.category=="agent" else (float(entity.get("height",0.7))*0.6 if link.category in ["door","prop"] else 0.25+float(entity.get("surface_height",0.0)))
		if link.category=="agent":
			var seat:=ResidenceSeats.occupied(entity,state.geometry)
			if not seat.is_empty():
				position=[seat.position.x,seat.position.y]
				height=seat.height+0.55*float(entity.appearance.get("height",1.0))
		output.append({"ref":ref,"position":position,"height":height})
	return output

func _entity(link:Dictionary)->Dictionary:
	var id:String=str(link.get("id",""))
	match str(link.get("category","")):
		"agent":return state.agents.get(id,{})
		"item":return state.items.get(id,{})
		"door":
			for door in state.geometry.doors:
				if door.id==id:return door
		"prop":
			for prop in state.geometry.props:
				if prop.id==id:return prop
	return {}

func _nearest_ref(id:String,category:String)->Dictionary:
	var result:Dictionary={};var distance:=INF
	for link in _refs.get(id,{}).values():
		if link.category!=category or not _reachable(id,link):continue
		var measured:=Spatial.point(state.agents[id]).distance_to(Spatial.point(_entity(link)))
		if measured<distance:distance=measured;result=link
	return result

func _container_accessible(container_id:String)->bool:
	if container_id.is_empty():return true
	for prop in state.geometry.props:
		if prop.id==container_id:return prop.get("storage",false) and prop.get("open",false) and not prop.get("locked",false)
	return false

func _reachable(id:String,link:Dictionary,allow_blind:bool=false)->bool:
	var target:=_entity(link)
	if target.is_empty():return false
	var actor:Dictionary=state.agents[id]
	var location:=Spatial.point(target)
	return Spatial.point(actor).distance_to(location)<=REACH and (allow_blind or Spatial.visible(actor,location,state.geometry,str(link.id),REACH)) and Spatial.clear_line(Spatial.point(actor),location,state.geometry,0.0,str(link.id),true)

func _inventory_item(id:String,slot:int)->Dictionary:
	if slot<0 or slot>=state.agents[id].inventory.size():return {}
	return state.items.get(state.agents[id].inventory[slot],{})

func _hands(actor:Dictionary)->int:
	return int(actor.body.left_arm!="broken")+int(actor.body.right_arm!="broken")

func _pain(actor:Dictionary)->float:
	var value:=0.0
	for limb in ["left_arm","right_arm","left_leg","right_leg"]:value+=20.0 if actor.body[limb]=="broken" else (8.0 if actor.body[limb]=="injured" else 0.0)
	return minf(100.0,value+(100.0-float(actor.health))*0.2)

func _drop(id:String,item_id:String)->void:
	if not state.items.has(item_id):return
	var item:Dictionary=state.items[item_id]
	state.agents[id].inventory.erase(item_id);item.holder="";item.container="";item.position=state.agents[id].position.duplicate();item.surface_height=0.0

func _consume_item(id:String,item:Dictionary)->void:
	item.quantity=int(item.quantity)-1
	if int(item.quantity)<=0:state.agents[id].inventory.erase(item.id);state.items.erase(item.id)

func _new_item(kind:String,label:String,position:Array,owner:String="community",holder:String="")->Dictionary:
	_next_item+=1
	var item_id:="item_%d"%_next_item
	var item:Dictionary={"id":item_id,"label":label,"kind":kind,"position":position.duplicate(),"holder":holder,"owner":owner,"container":"","surface_height":0.0,"quantity":1}
	state.items[item_id]=item
	if not holder.is_empty():state.agents[holder].inventory.append(item_id)
	return item

func _die(id:String,reason:String)->void:
	var actor:Dictionary=state.agents[id]
	if not actor.alive:return
	actor.alive=false;actor.health=0.0;actor.sleeping=false;actor.unconscious=false;actor.busy={"type":"dead"}
	for item_id in actor.inventory.duplicate():_drop(id,str(item_id))
	if not str(actor.carrying).is_empty():
		var passenger:Dictionary=state.agents[actor.carrying]
		passenger.carried_by="";passenger.busy={};passenger["surface_height"]=0.0
		actor.carrying=""
	if not str(actor.carried_by).is_empty():state.agents[actor.carried_by].carrying="";actor.carried_by=""
	_event(id,"death",true,actor.name+": "+reason,{})

func _speak(id:String,text_value:String)->Array[String]:
	var speaker:Dictionary=state.agents[id]
	var listeners: Array[String] = []
	for other_id in state.agents:
		if other_id==id:continue
		var listener:Dictionary=state.agents[other_id]
		var distance:=Spatial.point(speaker).distance_to(Spatial.point(listener))
		if listener.alive and not listener.sleeping and not listener.unconscious and distance<=9.0 and Spatial.clear_line(Spatial.point(speaker),Spatial.point(listener),state.geometry,0.0,"",true):
			listeners.append(str(other_id))
			var speech:Dictionary={"speaker":listener.known_people.get(id,"Голос рядом"),"text":text_value,"bearing":Spatial.bearing(listener,Spatial.point(speaker)),"distance":snappedf(distance,0.1),"source":"heard_speech","minute":state.minute}
			listener.heard.append(speech)
			personal_experience.emit(str(other_id),{"tick":state.tick,"minute":state.minute,"heard":[speech.duplicate(true)],"personal_results":[]})
			if listener.heard.size()>12:listener.heard.pop_front()
	return listeners

func _introduce(id:String,other_id:String)->void:
	var actor:Dictionary=state.agents[id]
	actor.known_people[other_id]=state.agents[other_id].name
	if not actor.contacts.values().has(other_id):actor.contacts["c%d"%actor.contacts.size()]=other_id

func _relation(observer:String,subject:String,change:float,reason:String)->void:
	if not state.agents.has(observer) or not state.agents.has(subject):return
	var actor:Dictionary=state.agents[observer]
	if not actor.relations.has(subject):actor.relations[subject]={"trust":0.0,"experience":[]}
	actor.relations[subject].trust=clampf(float(actor.relations[subject].trust)+change,-100.0,100.0)
	actor.relations[subject].experience.append({"minute":state.minute,"text":reason})
	if actor.relations[subject].experience.size()>20:actor.relations[subject].experience.pop_front()

func _witness_social(actor_id:String,kind:String,victim_id:String,trust_change:float)->void:
	var source:Dictionary=state.agents[actor_id]
	for observer_id in state.agents:
		if observer_id==actor_id or observer_id==victim_id:continue
		var observer:Dictionary=state.agents[observer_id]
		if Spatial.visible(observer,Spatial.point(source),state.geometry):
			_relation(observer_id,actor_id,trust_change,"Лично наблюдал: "+kind)
			_personal(observer_id,{"channel":"witness","text":"Наблюдал действие: "+kind,"source":"own_visual_experience"})

func _personal(id:String,entry:Dictionary)->void:
	entry=entry.duplicate(true);entry["minute"]=state.minute
	Episodes.record_source(state,id,entry)
	state.agents[id].personal_results.append(entry)
	personal_experience.emit(id,{"tick":state.tick,"minute":state.minute,"heard":[],"personal_results":[entry.duplicate(true)]})
	if state.agents[id].personal_results.size()>20:state.agents[id].personal_results.pop_front()

func _result(ok:bool,reason:String,details:Dictionary={})->Dictionary:
	return {"ok":ok,"reason":reason,"details":details}

func _event(actor:String,type_value:String,ok:bool,message:String,details:Dictionary)->void:
	var participants:Array=[]
	if state.agents.has(actor):participants.append(actor)
	for key in ["recipient","target","victim"]:
		if state.agents.has(str(details.get(key,""))) and not participants.has(str(details[key])):participants.append(str(details[key]))
	var place:Dictionary=_observer_place(state.agents[actor].position) if state.agents.has(actor) else {"id":"world","label":state.get("map_name","")}
	var item:Dictionary=state.items.get(str(details.get("item","")),{})
	var cause:Variant=details.get("cause",item.get("event_seq",null))
	var category:String="story" if type_value.begins_with("story") else ("intervention" if type_value=="intervention" or type_value.begins_with("god") else ("movement" if type_value in ["move","move_to","plan_completed","plan_interrupted"] else "action"))
	var event:Dictionary={"seq":int(state.event_cursor),"tick":int(state.tick),"minute":float(state.minute),"type":type_value,"actor":actor,"ok":ok,"message":message,"details":details.duplicate(true),"participants":participants,"place":place,"cause":cause,"category":category,"importance":3 if category=="story" else (2 if type_value in ["give","help","treat","attack","death","speak","send_message"] or not ok else 1),"visibility":"observer","phase":int(state.get("scenario_state",{}).get("phase",0))}
	state.event_cursor=int(state.event_cursor)+1
	if state.agents.has(actor):
		var resident:Dictionary=state.agents[actor]
		event["position"]=resident.position.duplicate()
		if ok and not resident.busy.is_empty() and not resident.busy.has("start_event_seq"):resident.busy["start_event_seq"]=event.seq
	if ok and not item.is_empty():item["event_seq"]=event.seq
	state.events.append(event);_new_events.append(event)
	Episodes.record_event(state,event)
	if state.events.size()>500:state.events.pop_front()

func _observer_place(position:Array)->Dictionary:
	for room in state.geometry.get("rooms",[]):
		if absf(float(position[0])-float(room.center[0]))<=float(room.size[0])*0.5 and absf(float(position[1])-float(room.center[1]))<=float(room.size[1])*0.5:return {"id":str(room.get("id",room.get("name",""))),"label":str(room.get("label",room.get("name",""))),"district":str(room.get("district",""))}
	return {"id":"passage","label":"Двор и переходы","district":""}

func observer_status(actor_id:String)->Dictionary:
	if not state.agents.has(actor_id):return {}
	var actor:Dictionary=state.agents[actor_id]
	var busy:Dictionary=actor.busy
	var activity:String=str(busy.get("type","idle"))
	if not actor.alive:activity="dead"
	elif actor.unconscious:activity="unconscious"
	elif actor.sleeping:activity="sleep"
	elif not str(actor.carried_by).is_empty():activity="carried"
	var target:String=str(busy.get("target",""))
	var target_label:String=target
	if state.agents.has(target):target_label=str(state.agents[target].name)
	else:
		for prop in state.geometry.props:
			if prop.id==target:target_label=str(prop.get("label",prop.kind));break
	var progress:float=-1.0
	if activity=="move_to" and float(busy.get("total_distance",0))>0.0:
		var remaining:float=0.0;var previous:Vector2=Spatial.point(actor)
		for waypoint in busy.get("path",[]):
			var next:=Vector2(float(waypoint[0]),float(waypoint[1]));remaining+=previous.distance_to(next);previous=next
		progress=clampf(1.0-remaining/float(busy.total_distance),0.0,1.0)
	var blocked:String=""
	if float(busy.get("blocked_minutes",0))>0.0:blocked="Проход занят; ищет обход."
	elif not actor.last_result.get("ok",true):blocked=str(actor.last_result.get("message",""))
	return {"activity":activity,"target":target_label,"progress":progress,"blocked_reason":blocked,"place":_observer_place(actor.position),"last_result":actor.last_result.duplicate(true)}

func _update_activity_statuses()->void:
	for actor_id in state.agents:state.agents[actor_id]["activity_status"]=observer_status(actor_id)

func _objective(key:String)->void:
	for objective in state.objectives:
		if objective.id==key:objective.complete=true

func _update_objectives()->void:
	if float(state.minute)>=1440.0:
		var all_alive:=true
		for actor in state.agents.values():all_alive=all_alive and actor.alive
		if all_alive:_objective("survive")
		else:
			for objective in state.objectives:
				if objective.id=="survive":objective["failed"]=true

func intervene(command:String,args:Dictionary)->Dictionary:
	command={"set_health":"health","set_body":"body","set_needs":"needs","set_profile":"profile","set_goal":"goal","set_role":"roles","set_roles":"roles","set_tokens":"tokens","set_memory":"memory"}.get(command,command)
	for numeric_key in ["health","hunger","fatigue","tokens","stock","daily_limit","delay","height","build"]:
		if args.has(numeric_key) and not _finite(args[numeric_key]):return _result(false,"Некорректное числовое значение вмешательства.")
	if args.has("position") and not _position_array(args.position):return _result(false,"Некорректная позиция вмешательства.")
	for array_key in ["roles","traits"]:
		if args.has(array_key):
			if not args[array_key] is Array:return _result(false,"Ожидается список строк.")
			for entry in args[array_key]:
				if not _text(entry,80):return _result(false,"Некорректный элемент списка.")
	var id:String=str(args.get("id",args.get("actor","")))
	var result:Dictionary=_result(false,"Неизвестное вмешательство.")
	match command:
		"episode_intervention","scenario_intervention":result=Episodes.intervene(self,args)
		"continue_sandbox":
			if not state.get("scenario_state",{}).get("completed",false):return _result(false,"Смена ещё продолжается.")
			state["completed_episode"]=state.scenario_state.duplicate(true)
			state["display_start_minute"]=state.scenario_state.display_start_minute
			state.erase("scenario_state")
			state.scenario="sandbox"
			state.objectives=[]
			state.scenario_description="Свободная жизнь после завершения смены."
			result=_result(true,"Смена завершена. Наблюдение за группой продолжается.")
		"spawn_item":
			var kind:String=str(args.get("kind","ration"))
			if kind not in ["ration","water","medkit","splint","knife","phone","camera","mug","key","diary"]:return _result(false,"Неизвестный тип предмета.")
			var position:Array=args.get("position",state.agents.get(id,{}).get("position",[0.0,0.0]))
			var item:=_new_item(kind,str(args.get("label",kind)),position,str(args.get("owner","community")),id if args.get("give",false) and state.agents.has(id) else "")
			if kind=="diary":item.entries=[]
			if kind=="phone":item.locked=false;item.account=id;item.session_owner=id;item.files=[]
			result=_result(true,"Создан предмет.",{"item":item.id})
		"set_network":state.network.online=bool(args.get("online",true));state.network.delay=clampf(float(args.get("delay",0.0)),0.0,1440.0);result=_result(true,"Изменены условия связи.")
		"set_terminal":state.terminal.stock=maxi(0,int(args.get("stock",state.terminal.stock)));state.terminal.daily_limit=maxi(0,int(args.get("daily_limit",state.terminal.daily_limit)));result=_result(true,"Изменён реестр терминала.")
		"door":
			for door in state.geometry.doors:
				if door.id==str(args.get("target","")):
					if not bool(args.get("open",door.open)):
						for occupant in state.agents.values():
							if occupant.alive and str(occupant.carried_by).is_empty() and Spatial.intersects(Spatial.point(occupant),Spatial.point(occupant),door,Spatial.RADIUS):return _result(false,"Нельзя закрыть дверь сквозь находящегося в проёме человека.")
					door.open=bool(args.get("open",door.open));door.locked=bool(args.get("locked",door.locked));result=_result(true,"Изменена дверь.")
		"announce":
			for actor_id in state.agents:_personal(actor_id,{"channel":"announcement","text":str(args.get("text","")),"source":"player_intervention"})
			result=_result(true,"Передано явное объявление.")
		"action":
			if args.get("action") is Dictionary:result=submit(id,args.action,int(state.run_id))
		_:
			if not state.agents.has(id):return _result(false,"Персонаж не выбран.")
			var actor:Dictionary=state.agents[id]
			match command:
				"health","body":
					var staged:Dictionary=actor.duplicate(true)
					if args.has("health"):staged.health=clampf(float(args.health),0.0,100.0);staged.alive=staged.health>0.0
					if args.get("body") is Dictionary:
						for key in args.body:
							if key=="blind":staged.body.blind=bool(args.body[key])
							elif key in ["left_arm","right_arm","left_leg","right_leg"] and args.body[key] in ["healthy","injured","broken"]:staged.body[key]=args.body[key]
					staged.unconscious=bool(args.get("unconscious",staged.unconscious))
					staged.sleeping=bool(args.get("sleeping",staged.sleeping)) and not staged.unconscious
					var bed_id:String=str(actor.busy.get("bed",""))
					if staged.alive and ((not bed_id.is_empty() and not staged.sleeping) or (not actor.alive and not Spatial.walkable(Spatial.point(staged),state.geometry,state.agents,id))):
						var safe:=Vector2.INF
						for radius in [.75,1.5,2.0,2.5]:
							for angle in range(0,360,30):
								var trial:=Spatial.point(staged)+Vector2.from_angle(deg_to_rad(float(angle)))*float(radius)
								if Spatial.walkable(trial,state.geometry,state.agents,id):safe=trial;break
							if safe!=Vector2.INF:break
						if safe==Vector2.INF:return _result(false,"Нет безопасного места для пробуждения или восстановления тела.")
						staged.position=[safe.x,safe.y];staged["surface_height"]=0.0;bed_id=""
					staged.busy={}
					if staged.sleeping:
						staged.busy={"type":"sleep","remaining":float(actor.busy.get("remaining",60.0))}
						if not bed_id.is_empty():staged.busy["bed"]=bed_id
					elif staged.unconscious:staged.busy={"type":"unconscious","remaining":30.0}
					elif not str(staged.carried_by).is_empty():staged.busy={"type":"carried"}
					actor.clear();actor.merge(staged,true)
					if _hands(actor)==0:
						for item_id in actor.inventory.duplicate():_drop(id,item_id)
					if actor.health<=0.0:actor.alive=true;_die(id,"Явное вмешательство наблюдателя.")
					result=_result(true,"Изменено тело персонажа.")
				"needs":
					for key in ["hunger","fatigue"]:
						if args.has(key):actor.needs[key]=clampf(float(args[key]),0.0,100.0)
					result=_result(true,"Изменены потребности.")
				"profile":
					for key in ["foundation","goal"]:
						if args.has(key):actor.profile[key]=str(args[key])
					if args.get("traits") is Array:actor.profile.traits=args.traits.duplicate()
					result=_result(true,"Профиль изменён явным вмешательством.")
				"goal":
					actor.profile.goal=str(args.get("goal",""))
					if actor.alive and not actor.sleeping and not actor.unconscious and str(actor.carried_by).is_empty():actor.busy={}
					result=_result(true,"Назначена текущая цель.")
				"roles":actor.roles=args.get("roles",[]).duplicate();result=_result(true,"Изменены полномочия.")
				"tokens":actor.tokens=maxi(0,int(args.get("tokens",0)));result=_result(true,"Изменён баланс жетонов.")
				"appearance":
					var bounds:Dictionary={"face":5,"hair":5,"outfit":3,"shoes":1}
					for key in bounds:
						if args.has(key):actor.appearance[key]=clampi(int(args[key]),0,int(bounds[key]))
					for key in ["skin","hair_color","color"]:
						if args.has(key):
							if key=="color":actor.color=str(args[key])
							else:actor.appearance[key]=str(args[key])
					for key in ["height","build"]:
						if args.has(key):actor.appearance[key]=clampf(float(args[key]),0.85,1.2)
					result=_result(true,"Изменена реальная внешность.")
				"teleport":
					var p:Array=args.get("position",actor.position)
					var point:=Vector2(float(p[0]),float(p[1]))
					if Spatial.walkable(point,state.geometry,state.agents,id):
						if not str(actor.carried_by).is_empty():state.agents[actor.carried_by].carrying="";actor.carried_by=""
						actor.position=p.duplicate();actor.busy={};actor["surface_height"]=0.0
						if not actor.alive:actor.busy={"type":"dead"}
						elif actor.sleeping:actor.busy={"type":"sleep","remaining":60.0}
						elif actor.unconscious:actor.busy={"type":"unconscious","remaining":30.0}
						if not str(actor.carrying).is_empty():state.agents[actor.carrying].position=p.duplicate()
						result=_result(true,"Персонаж перемещён вмешательством.")
					else:result=_result(false,"Недопустимая позиция.")
				"memory":
					actor.memory_override={"text":str(args.get("text","")),"clear":bool(args.get("clear",false)),"version":int(actor.memory_override.get("version",0))+1}
					if actor.memory_override.clear:actor.heard.clear();actor.personal_results.clear()
					result=_result(true,"Задано явное вмешательство в память.")
	if result.ok:_event("observer","intervention",true,result.reason,{"command":command,"args":args.duplicate(true)})
	return result

func export_state()->Dictionary:
	return {"schema":2,"world":snapshot(),"next_item":_next_item}

func device_screen(actor_id:String)->Dictionary:
	return Society.screen(self,actor_id)

func attach_photo(actor_id:String,artifact_id:String,image_ref:String)->bool:
	var artifact:Dictionary=state.artifacts.get(artifact_id,{})
	if artifact.is_empty() or artifact.creator!=actor_id or image_ref.is_empty() or not str(artifact.image_ref).is_empty() or artifact.get("pending_capture",true):return false
	artifact.image_ref=image_ref
	_event(actor_id,"photo_attached",true,"К фотографии прикреплены исходные пиксели реального кадра.",{"artifact_id":artifact_id,"image_ref":image_ref})
	return true

func apply_memory_traits(actor_id:String,traits:Array)->bool:
	if not state.agents.has(actor_id) or traits.size()>12:return false
	for secondary_trait in traits:
		if not secondary_trait is String or secondary_trait.is_empty() or secondary_trait.length()>80:return false
	state.agents[actor_id].profile.traits=traits.duplicate()
	_event(actor_id,"memory_profile",true,"Агент памяти обновил допустимые вторичные черты.",{"traits":traits.duplicate()})
	return true

func import_state(data:Dictionary)->bool:
	var candidate:Variant=data.get("world",data)
	if not _valid_world(candidate):return false
	_serial=maxi(_serial,int(candidate.run_id))+1
	state=candidate.duplicate(true);state.run_id=_serial
	if not state.network.has("groups"):state.network["groups"]={}
	_next_item=maxi(int(data.get("next_item",1000)),1000)
	_refs.clear();_intentions.clear();_new_events.clear()
	_observation_captures.clear()
	_update_activity_statuses()
	return true

func _valid_world(value:Variant)->bool:
	if not value is Dictionary or value.get("version")!=2:return false
	for key in ["agents","items","geometry","terminal","economy","network","artifacts"]:
		if not value.get(key) is Dictionary:return false
	for key in ["events","objectives"]:
		if not value.get(key) is Array:return false
	for key in ["run_id","tick","minute","event_cursor"]:
		if not _finite(value.get(key)):return false
	if value.agents.size()<1 or value.agents.size()>20:return false
	var geometry:Dictionary=value.geometry
	if not geometry.get("bounds") is Array or geometry.bounds.size()!=4:return false
	for limit in geometry.bounds:
		if not _finite(limit):return false
	if float(geometry.bounds[0])>=float(geometry.bounds[1]) or float(geometry.bounds[2])>=float(geometry.bounds[3]):return false
	for key in ["walls","doors","props"]:
		if not geometry.get(key) is Array:return false
		for box in geometry[key]:
			if not box is Dictionary or not box.get("center") is Array or box.center.size()!=2 or not box.get("size") is Array or box.size.size()!=2:return false
			for number in box.center+box.size:
				if not _finite(number):return false
			if not _text(box.get("id")) or float(box.size[0])<=0.0 or float(box.size[1])<=0.0 or not _finite(box.get("height")) or float(box.height)<=0.0:return false
			if key=="doors" and (not box.get("open") is bool or not box.get("locked") is bool):return false
	for key in ["rooms","districts"]:
		if not geometry.get(key,[]) is Array:return false
		for place in geometry.get(key,[]):
			if not place is Dictionary or not _position_array(place.get("center")) or not _position_array(place.get("size")):return false
			if float(place.size[0])<=0.0 or float(place.size[1])<=0.0:return false
	if value.has("scenario_state") and (not _valid_episode(value.scenario_state,value.agents) or value.get("scenario")!=value.scenario_state.id or not geometry.get("rooms") is Array):return false
	if value.has("completed_episode") and (not _valid_episode(value.completed_episode,value.agents) or not value.completed_episode.completed):return false
	var held:Dictionary={}
	for id in value.agents:
		var actor:Variant=value.agents[id]
		if not actor is Dictionary:return false
		for key in ["profile","needs","body","appearance","busy","last_action","last_result","relations","contacts","known_cells","known_people","memory_override"]:
			if not actor.get(key) is Dictionary:return false
		for key in ["inventory","roles","heard","personal_results"]:
			if not actor.get(key) is Array:return false
		if not actor.get("position") is Array or actor.position.size()!=2:return false
		for number in actor.position+[actor.get("heading"),actor.get("health"),actor.get("pain"),actor.get("tokens"),actor.needs.get("hunger"),actor.needs.get("fatigue")]:
			if not _finite(number):return false
		for bounded in [actor.health,actor.pain,actor.needs.hunger,actor.needs.fatigue]:
			if float(bounded)<0.0 or float(bounded)>100.0:return false
		if not _whole(actor.tokens) or int(actor.tokens)<0:return false
		for key in ["alive","sleeping","unconscious"]:
			if not actor.get(key) is bool:return false
		if actor.alive!=(float(actor.health)>0.0):return false
		if not actor.body.get("blind") is bool:return false
		for key in ["left_arm","right_arm","left_leg","right_leg"]:
			if actor.body.get(key) not in ["healthy","injured","broken"]:return false
		if not actor.get("id") is String or actor.id!=id or not actor.get("name") is String or not actor.get("color") is String:return false
		if not _valid_actor_details(actor,value.agents):return false
		if actor.busy.has("seat_positioned"):
			var seat:=ResidenceSeats.occupied(actor,geometry)
			if seat.is_empty() or Spatial.point(actor).distance_to(seat.approach)>0.02 or absf(angle_difference(deg_to_rad(float(actor.heading)),deg_to_rad(seat.heading)))>0.02:return false
		for item_id in actor.inventory:
			if held.has(item_id) or not value.items.has(item_id):return false
			held[item_id]=id
		var on_bed:=false
		if actor.sleeping and not str(actor.busy.get("bed","")).is_empty():
			for prop in geometry.props:
				if prop.id==actor.busy.bed and prop.kind in ["bed","medicalbed"] and Spatial.point(prop).distance_to(Spatial.point(actor))<0.05:on_bed=true
		if actor.alive and not on_bed and str(actor.get("carried_by","")).is_empty() and not Spatial.walkable(Spatial.point(actor),geometry,value.agents,str(id)):return false
	for item_id in value.items:
		var item:Variant=value.items[item_id]
		if not item is Dictionary or not item.get("position") is Array or item.position.size()!=2:return false
		for key in ["id","kind","label","holder","owner","container"]:
			if not item.get(key) is String:return false
		for number in item.position+[item.get("quantity"),item.get("surface_height")]:
			if not _finite(number):return false
		if not _whole(item.quantity) or int(item.quantity)<=0 or int(item.quantity)>1000000 or float(item.surface_height)<0.0 or float(item.surface_height)>10.0:return false
		if item.id!=item_id:return false
		if item.has("files"):
			if not item.files is Array:return false
			for file_id in item.files:
				if not file_id is String or not value.artifacts.has(file_id):return false
		if item.has("locked") and not item.locked is bool:return false
		for account_key in ["account","session_owner"]:
			if item.has(account_key) and (not item[account_key] is String or (not item[account_key].is_empty() and not value.agents.has(item[account_key]))):return false
		if item.has("entries"):
			if not item.entries is Array:return false
			for entry in item.entries:
				if not entry is Dictionary or not _finite(entry.get("minute")) or not _text(entry.get("text"),2000):return false
		if item.has("artifact_id") and not value.artifacts.has(item.artifact_id):return false
		if not str(item.holder).is_empty() and (held.get(item_id,"")!=item.holder or not value.agents.has(item.holder)):return false
		if held.has(item_id) and held[item_id]!=item.holder:return false
	return _valid_services(value)

func _valid_episode(story:Variant,agents:Dictionary)->bool:
	if not story is Dictionary or story.get("id") not in Episodes.IDS or not story.get("completed") is bool:return false
	for key in ["title","description","phase_title","current_problem"]:
		if not _text(story.get(key)):return false
	if not _whole(story.get("phase")) or int(story.phase)<1 or int(story.phase)>3:return false
	for key in ["deadline","display_start_minute"]:
		if not _finite(story.get(key)) or float(story[key])<0.0:return false
	for key in ["triggered","injured","initial_poor","debrief"]:
		if not story.get(key) is Array:return false
		for entry in story[key]:
			if not _text(entry) or (key in ["injured","initial_poor"] and not agents.has(entry)):return false
	if not story.get("interventions") is Array or not story.get("outcome") is Dictionary:return false
	for card in story.interventions:
		if not card is Dictionary or card.get("id") not in ["announcement","reserve","policy"] or not card.get("used") is bool or not _text(card.get("title")):return false
	if story.completed and (story.outcome.get("kind") not in ["success","failure","partial"] or not _text(story.outcome.get("title"))):return false
	if not story.get("metrics") is Dictionary or not _whole(story.metrics.get("interventions")):return false
	for key in ["food_consumed","food_received","food_help","verified_sources","funded"]:
		if not story.metrics.get(key,{} if key=="funded" else null) is Dictionary:return false
		for id in story.metrics.get(key,{}):
			if not agents.has(id):return false
			var amount:Variant=story.metrics[key][id]
			if key=="verified_sources" or (key=="funded" and amount is bool):
				if not amount is bool:return false
			elif not _whole(amount) or int(amount)<0:return false
	if not story.get("moments",{}) is Dictionary:return false
	for moment in story.get("moments",{}).values():
		if not moment is Dictionary or not _finite(moment.get("minute")) or not _text(moment.get("ru")) or not _text(moment.get("en")):return false
	return true

func _valid_actor_details(actor:Dictionary,agents:Dictionary)->bool:
	if not _text(actor.profile.get("foundation"),4000) or not _text(actor.profile.get("goal"),2000) or not actor.profile.get("traits") is Array:return false
	for secondary_trait in actor.profile.traits:
		if not _text(secondary_trait,80):return false
	for key in ["face","hair","outfit"]:
		if not _whole(actor.appearance.get(key)) or int(actor.appearance[key])<0 or int(actor.appearance[key])>7:return false
	for key in ["skin","hair_color"]:
		if not _text(actor.appearance.get(key),32):return false
	for key in ["height","build"]:
		if not _finite(actor.appearance.get(key)) or float(actor.appearance[key])<0.8 or float(actor.appearance[key])>1.3:return false
	for key in ["carrying","carried_by","device_app"]:
		if not actor.get(key) is String:return false
	if not _whole(actor.get("device_slot")) or int(actor.device_slot)<-1:return false
	for key in ["carrying","carried_by"]:
		if not actor[key].is_empty() and (not agents.has(actor[key]) or actor[key]==actor.id):return false
	if not actor.carried_by.is_empty() and agents[actor.carried_by].get("carrying","")!=actor.id:return false
	if not actor.carrying.is_empty() and agents[actor.carrying].get("carried_by","")!=actor.id:return false
	for role_name in actor.roles:
		if not _text(role_name,80):return false
	for ref in actor.contacts:
		if not ref is String or not actor.contacts[ref] is String or not agents.has(actor.contacts[ref]):return false
	for other_id in actor.known_people:
		if not agents.has(other_id) or not _text(actor.known_people[other_id],100):return false
	for cell in actor.known_cells:
		if not cell is String or not actor.known_cells[cell] is bool:return false
	for relation in actor.relations.values():
		if not relation is Dictionary or not _finite(relation.get("trust")) or absf(float(relation.trust))>100.0 or not relation.get("experience") is Array:return false
		for experience in relation.experience:
			if not experience is Dictionary or not _finite(experience.get("minute")) or not _text(experience.get("text"),2000):return false
	for entry in actor.personal_results:
		if not entry is Dictionary or not _text(entry.get("channel"),80) or not _finite(entry.get("minute")):return false
	for speech in actor.heard:
		if not speech is Dictionary or not _text(speech.get("speaker"),100) or not _text(speech.get("text"),2000):return false
		for key in ["minute","bearing","distance"]:
			if not _finite(speech.get(key)):return false
	if not actor.busy.is_empty():
		if actor.busy.get("type") not in ["move_to","rest","sleep","wait","consume","attack","defend","treat","unconscious","carried","dead"]:return false
		if actor.busy.type=="move_to":
			if not actor.busy.get("path") is Array or not _text(actor.busy.get("mode"),40):return false
			for waypoint in actor.busy.path:
				if not _position_array(waypoint):return false
		elif actor.busy.type not in ["dead","carried"] and not _finite(actor.busy.get("remaining")):return false
	if actor.has("healing"):
		if not actor.healing is Dictionary:return false
		for deadline in actor.healing.values():
			if not _finite(deadline):return false
	if actor.has("queue_tickets"):
		if not actor.queue_tickets is Dictionary:return false
		for kind in actor.queue_tickets:
			if kind not in ["camera","phone"] or not _text(actor.queue_tickets[kind],100):return false
	for refs_key in ["offer_refs","service_contacts"]:
		if actor.has(refs_key) and not actor[refs_key] is Dictionary:return false
	if actor.has("service_refs"):
		if not actor.service_refs is Dictionary:return false
		for refs in actor.service_refs.values():
			if not refs is Dictionary:return false
	return _json_value(actor.memory_override)

func _valid_services(value:Dictionary)->bool:
	var terminal:Dictionary=value.terminal
	if not _position_array(terminal.get("position")) or not terminal.get("issued") is Dictionary or not terminal.get("queues") is Dictionary or not terminal.get("loans") is Dictionary:return false
	for key in ["stock","daily_limit"]:
		if not _whole(terminal.get(key)) or int(terminal[key])<0:return false
	if not _finite(terminal.get("slot_minutes")) or float(terminal.slot_minutes)<=0.0:return false
	for count in terminal.issued.values():
		if not _whole(count) or int(count)<0:return false
	for kind in ["camera","phone"]:
		if not terminal.queues.get(kind) is Array:return false
		var seen:Dictionary={}
		for actor_id in terminal.queues[kind]:
			if not actor_id is String or not value.agents.has(actor_id) or seen.has(actor_id):return false
			seen[actor_id]=true
	for loan in terminal.loans.values():
		if not loan is Dictionary or not value.agents.has(loan.get("actor")) or not _finite(loan.get("deadline")) or not loan.get("overdue") is bool or loan.get("kind") not in ["camera","phone"]:return false
		if loan.has("ticket") and not _text(loan.ticket,100):return false
	var economy:Dictionary=value.economy
	for key in ["shop_stock","prices","offers"]:
		if not economy.get(key) is Dictionary:return false
	for key in ["shop_stock","prices"]:
		for number in economy[key].values():
			if not _whole(number) or int(number)<0:return false
	if not _whole(economy.get("next_offer")) or int(economy.next_offer)<0:return false
	for offer in economy.offers.values():
		if not offer is Dictionary or not value.agents.has(offer.get("from")) or not value.agents.has(offer.get("to")):return false
		for key in ["id","item","promise","status"]:
			if not offer.get(key) is String:return false
		for key in ["tokens","request_tokens","deadline","created"]:
			if not _finite(offer.get(key)) or float(offer[key])<0.0:return false
		if offer.status not in ["proposed","accepted","completed","claimed","fulfilled","expired"]:return false
	var network:Dictionary=value.network
	if not network.get("online") is bool or not _finite(network.get("delay")) or float(network.delay)<0.0 or not _whole(network.get("next_id")) or int(network.next_id)<0:return false
	for key in ["messages","topics","polls","games","pages"]:
		if not network.get(key) is Dictionary:return false
	if network.has("groups"):
		if not network.groups is Dictionary:return false
		for group in network.groups.values():
			if not group is Dictionary or not _text(group.get("title"),120) or not group.get("members") is Array or not value.agents.has(group.get("creator")):return false
			for member in group.members:
				if not value.agents.has(member):return false
	for message in network.messages.values():
		if not message is Dictionary or not value.agents.has(message.get("sender")) or not value.agents.has(message.get("recipient")) or not value.agents.has(message.get("operator")):return false
		for key in ["id","text","original_text","attachment","original_attachment","status"]:
			if not message.get(key) is String:return false
		for key in ["created","deliver_at","revision"]:
			if not _finite(message.get(key)) or float(message[key])<0.0:return false
		if not message.get("deleted") is bool or not message.get("revisions") is Array:return false
		for key in ["read_by","deleted_for"]:
			if not message.get(key) is Array:return false
			for actor_id in message[key]:
				if not value.agents.has(actor_id):return false
		if message.status not in ["queued","delivered","read","deleted"]:return false
	for topic in network.topics.values():
		if not topic is Dictionary or not _text(topic.get("title"),120) or not value.agents.has(topic.get("author")) or not topic.get("posts") is Array:return false
		for post in topic.posts:
			if not post is Dictionary or not value.agents.has(post.get("author")) or not _text(post.get("text"),2000) or not _finite(post.get("minute")):return false
	for poll in network.polls.values():
		if not poll is Dictionary or not _text(poll.get("title"),120) or not value.agents.has(poll.get("author")) or not poll.get("options") is Array or poll.options.size()<2 or poll.options.size()>8:return false
		if not poll.get("votes") is Dictionary or not _finite(poll.get("deadline")) or not poll.get("closed") is bool or not _whole(poll.get("result")) or int(poll.result)<-1 or int(poll.result)>=poll.options.size():return false
		for option in poll.options:
			if not _text(option,120):return false
		for actor_id in poll.votes:
			if not value.agents.has(actor_id) or not _whole(poll.votes[actor_id]) or int(poll.votes[actor_id])<0 or int(poll.votes[actor_id])>=poll.options.size():return false
	for game in network.games.values():
		if not game is Dictionary or not game.get("players") is Array or game.players.size()!=2 or not game.get("board") is Array or game.board.size()!=9:return false
		for actor_id in game.players:
			if not value.agents.has(actor_id):return false
		for cell in game.board:
			if cell not in [".","X","O"]:return false
		if game.get("turn") not in [0,1] or not game.get("finished") is bool or not game.get("result") is String:return false
	for page in network.pages.values():
		if not page is Dictionary or not _text(page.get("title"),120) or not _text(page.get("text"),2000) or not _whole(page.get("revision")) or int(page.revision)<1 or not page.get("author") is String:return false
	for artifact_id in value.artifacts:
		var artifact:Variant=value.artifacts[artifact_id]
		if not artifact is Dictionary or artifact.get("id")!=artifact_id or not value.agents.has(artifact.get("creator")) or not artifact.get("owner") is String:return false
		if not _finite(artifact.get("created")) or not artifact.get("image_ref") is String or not artifact.get("digital") is bool or not artifact.get("pending_capture") is bool:return false
		if not artifact.get("source_pose") is Dictionary or not _position_array(artifact.source_pose.get("position")) or not _finite(artifact.source_pose.get("heading")):return false
	var previous:=-1
	for event in value.events:
		if not event is Dictionary or not _whole(event.get("seq")) or int(event.seq)<=previous or not _whole(event.get("tick")) or not _finite(event.get("minute")) or not event.get("details") is Dictionary or not event.get("ok") is bool:return false
		for key in ["type","actor","message"]:
			if not event.get(key) is String:return false
		previous=int(event.seq)
	if previous>=int(value.event_cursor):return false
	return _json_value(value)

func _text(value:Variant,maximum:int=4000)->bool:
	return value is String and value.length()<=maximum

func _whole(value:Variant)->bool:
	return _finite(value) and float(value)==floorf(float(value))

func _position_array(value:Variant)->bool:
	return value is Array and value.size()==2 and _finite(value[0]) and _finite(value[1])

func _json_value(value:Variant,depth:int=0)->bool:
	if depth>30:return false
	if value==null or value is String or value is bool:return true
	if value is int or value is float:return is_finite(float(value))
	if value is Array:
		for entry in value:
			if not _json_value(entry,depth+1):return false
		return true
	if value is Dictionary:
		for key in value:
			if not (key is String or key is StringName) or not _json_value(value[key],depth+1):return false
		return true
	return false

func _finite(value:Variant)->bool:
	return (value is int or value is float) and is_finite(float(value))
