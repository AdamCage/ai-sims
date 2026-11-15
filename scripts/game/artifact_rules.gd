extends RefCounted
## Exact photos are attached by the renderer at this module's frozen capture event.

static func execute(world:Object,id:String,action:Dictionary,resolved:Dictionary)->Dictionary:
	var actor:Dictionary=world.state.agents[id]
	var kind:String=action.type
	if world._hands(actor)==0:return world._result(false,"Обе руки сломаны: работа с предметами недоступна.")
	if kind!="destroy" and actor.body.blind:return world._result(false,"Зрение, чтение и запись недоступны.")
	match kind:
		"write_diary":
			var diary:Dictionary={}
			for item_id in actor.inventory:
				if world.state.items[item_id].kind=="diary":diary=world.state.items[item_id];break
			if diary.is_empty():return world._result(false,"Нет доступного дневника.")
			if str(action.text).length()>400:return world._result(false,"Запись должна быть краткой: до400 символов.")
			if not diary.has("entries"):diary.entries=[]
			diary.entries.append({"minute":world.state.minute,"text":str(action.text),"author":id})
			return world._result(true,"Добровольная запись сохранена в предмете.")
		"read_diary":
			var diary:Dictionary=world._inventory_item(id,int(action.slot))
			if diary.is_empty() or diary.kind!="diary":return world._result(false,"В этом слоте нет дневника.")
			var entries:Array=diary.get("entries",[])
			var safe:Array=[]
			for entry in entries.slice(maxi(0,entries.size()-8)):safe.append({"minute":entry.minute,"text":entry.text})
			world._personal(id,{"channel":"diary","entries":safe,"source":"read_physical_artifact"})
			return world._result(true,"Дневник прочитан как новый личный опыт.")
		"take_photo":
			var device:Dictionary={}
			for item_id in actor.inventory:
				var item:Dictionary=world.state.items[item_id]
				if item.kind in ["camera","phone"] and not item.get("locked",false):device=item;break
			if device.is_empty():return world._result(false,"Нужен доступный фотоаппарат или телефон.")
			var artifact_id:=_next(world)
			var digital:bool=bool(action.get("digital",true))
			world.state.artifacts[artifact_id]={"id":artifact_id,"kind":"photo","creator":id,"owner":id,"created":float(world.state.minute),"image_ref":"","digital":digital,"pending_capture":true,"source_pose":{"position":actor.position.duplicate(),"heading":actor.heading},"device":device.id}
			if digital:
				if not device.has("files"):device.files=[]
				device.files.append(artifact_id)
			else:
				var photo:Dictionary=world._new_item("photo","Фотография",actor.position,id,id);photo["artifact_id"]=artifact_id
			return world._result(true,"Запрошена настоящая съёмка в конце текущего шага.",{"artifact_id":artifact_id})
		"view_photo":
			var artifact_id:=from_slot(world,id,int(action.slot),int(action.get("index",-1)))
			var artifact:Dictionary=world.state.artifacts.get(artifact_id,{})
			if artifact.is_empty() or str(artifact.image_ref).is_empty():return world._result(false,"Нет готового доступного снимка.")
			actor["gallery_selection"]=artifact_id
			world._personal(id,{"channel":"viewed_photo","image_ref":artifact.image_ref,"text":"Рассмотрен доступный точный снимок прошлого.","source":"viewed_own_artifact","original_minute":artifact.created})
			return world._result(true,"Рассмотрена фотография как новый личный опыт.")
		"show_photo":
			if resolved.get("category")!="agent" or not world._reachable(id,resolved):return world._result(false,"Зритель вне досягаемости.")
			var target:Dictionary=world._entity(resolved)
			if target.body.blind or target.sleeping or target.unconscious:return world._result(false,"Зритель не может рассмотреть изображение.")
			var artifact_id:=from_slot(world,id,int(action.slot),int(action.get("index",-1)))
			var artifact:Dictionary=world.state.artifacts.get(artifact_id,{})
			if artifact.is_empty() or str(artifact.image_ref).is_empty():return world._result(false,"Нет готовой доступной фотографии.")
			world._personal(str(target.id),{"channel":"viewed_photo","image_ref":artifact.image_ref,"text":"Показан точный снимок прошлого момента.","source":"shown_artifact","original_minute":artifact.created})
			return world._result(true,"Фото показано; владение экземпляром не передавалось.")
		"copy_photo":
			var source_id:=from_slot(world,id,int(action.slot),int(action.get("index",-1)))
			var artifact:Dictionary=world.state.artifacts.get(source_id,{})
			if artifact.is_empty() or str(artifact.image_ref).is_empty():return world._result(false,"Нет доступного снимка для копирования.")
			var copy_id:=_next(world)
			var copy:Dictionary=artifact.duplicate(true);copy.id=copy_id;copy.owner=id;copy["copied_at"]=world.state.minute;copy["source_artifact"]=source_id
			world.state.artifacts[copy_id]=copy
			var source:Dictionary=world._inventory_item(id,int(action.slot))
			if source.kind in ["phone","camera"]:source.files.append(copy_id)
			else:
				var photo:Dictionary=world._new_item("photo","Копия фотографии",actor.position,id,id);photo["artifact_id"]=copy_id
			return world._result(true,"Создан независимый экземпляр снимка.")
		"destroy":
			var item:Dictionary=world._inventory_item(id,int(action.slot))
			if item.is_empty():return world._result(false,"Слот пуст.")
			actor.inventory.erase(item.id);world.state.items.erase(item.id)
			if int(actor.get("device_slot",-1))==int(action.slot):actor.device_slot=-1;actor.device_app=""
			return world._result(true,"Уничтожен предмет; независимые копии и чужой опыт сохранены.")
	return world._result(false,"Неизвестное действие с артефактом.")

static func from_slot(world:Object,id:String,slot:int,index:int=-1)->String:
	if index < -1:return ""
	var item:Dictionary=world._inventory_item(id,slot)
	if item.is_empty():return ""
	if item.kind=="photo":return str(item.get("artifact_id",""))
	if item.kind in ["camera","phone"] and not item.get("locked",false):
		var files:Array=item.get("files",[])
		if not files.is_empty() and (index==-1 or index<files.size()):return str(files[-1] if index==-1 else files[index])
	return ""

static func _next(world:Object)->String:
	var key:="photo_%d"%int(world.state.network.next_id)
	world.state.network.next_id=int(world.state.network.next_id)+1
	return key

static func advance(world:Object,_minutes:float)->void:
	for artifact in world.state.artifacts.values():
		if artifact.get("pending_capture",false):
			artifact.pending_capture=false;artifact.created=float(world.state.minute)
			var actor:Dictionary=world.state.agents[artifact.creator]
			artifact.source_pose={"position":actor.position.duplicate(),"heading":actor.heading}
			world._event(str(artifact.creator),"photo_capture",true,"Зафиксирован момент настоящей съёмки.",{"artifact_id":artifact.id})
