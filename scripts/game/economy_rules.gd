extends RefCounted
const Spatial=preload("res://scripts/game/spatial_rules.gd")

static func execute(world:Object,id:String,action:Dictionary,resolved:Dictionary)->Dictionary:
	var actor:Dictionary=world.state.agents[id]
	match str(action.type):
		"request_ration":return terminal_request(world,id,"ration")
		"join_queue":return terminal_request(world,id,str(action.get("kind","camera")))
		"return_device":
			if world._hands(actor)==0:return world._result(false,"Нельзя вернуть устройство руками: нужна помощь.")
			var item:Dictionary=world._inventory_item(id,int(action.slot))
			if item.is_empty() or not world.state.terminal.loans.has(item.id):return world._result(false,"Нет выданного общего устройства в этом слоте.")
			if not _near_terminal(world,actor):return world._result(false,"Нужно подойти к терминалу для возврата.")
			actor.inventory.erase(item.id);item.holder="";item.container="terminal";item.position=world.state.terminal.position.duplicate()
			world.state.terminal.loans.erase(item.id)
			return world._result(true,"Устройство возвращено; файлы на нём сохранены.")
		"transfer_tokens":
			if resolved.get("category")!="agent" or not world._reachable(id,resolved):return world._result(false,"Получатель вне досягаемости.")
			var other:Dictionary=world._entity(resolved)
			if world._hands(actor)==0 or world._hands(other)==0 or not other.alive:return world._result(false,"Сторона не может передавать или принимать жетоны.")
			var amount:=int(action.tokens)
			if amount<=0 or int(actor.tokens)<amount:return world._result(false,"Недостаточно жетонов.")
			actor.tokens=int(actor.tokens)-amount;other.tokens=int(other.tokens)+amount
			world._relation(str(other.id),id,3.0,"Передал жетоны.")
			return world._result(true,"Передано %d жетонов."%amount)
		"buy","sell":return _shop(world,id,action,resolved)
		_:return _offer(world,id,action,resolved)

static func _near_terminal(world:Object,actor:Dictionary)->bool:
	var p:Array=world.state.terminal.position
	var terminal_id:=""
	for prop in world.state.geometry.props:
		if prop.kind=="terminal":terminal_id=str(prop.id);break
	return Spatial.point(actor).distance_to(Vector2(float(p[0]),float(p[1])))<=2.0 and Spatial.clear_line(Spatial.point(actor),Vector2(float(p[0]),float(p[1])),world.state.geometry,0.0,terminal_id,true)

static func terminal_request(world:Object,id:String,kind:String)->Dictionary:
	var actor:Dictionary=world.state.agents[id]
	if not _near_terminal(world,actor):return world._result(false,"Сначала подойдите к терминалу.")
	if world._hands(actor)==0 or actor.body.blind:return world._result(false,"Экран/управление терминала недоступны из-за состояния тела.")
	world._personal(id,{"channel":"terminal","text":"Личный лимит: %d пайков за сутки. Запас: %d."%[world.state.terminal.daily_limit,world.state.terminal.stock],"source":"read_terminal"})
	for experience in actor.personal_results:
		if experience.get("channel")=="message":world._objective("verify");break
	if kind=="ration":
		var day:=floori(float(world.state.minute)/1440.0)
		var key:="%s:%d"%[id,day]
		var issued:=int(world.state.terminal.issued.get(key,0))
		if issued>=int(world.state.terminal.daily_limit):return world._result(false,"Личный суточный паёк уже получен.")
		if int(world.state.terminal.stock)<=0:return world._result(false,"Запас терминала исчерпан.")
		world.state.terminal.stock=int(world.state.terminal.stock)-1;world.state.terminal.issued[key]=issued+1
		world._new_item("ration","Личный паёк",actor.position,id,id)
		return world._result(true,"Выдан один реальный паёк по личному праву.")
	if kind not in ["camera","phone"]:return world._result(false,"Такое оборудование не выдаётся.")
	for loan in world.state.terminal.loans.values():
		if loan.actor==id:return world._result(false,"Сначала верните прежнее общее оборудование.")
	var queue:Array=world.state.terminal.queues[kind]
	if not queue.has(id):queue.append(id)
	if _issue(world,id,kind):return world._result(true,"Общее устройство выдано на один игровой час.")
	return world._result(true,"Место в очереди: %d."%(queue.find(id)+1))

static func _issue(world:Object,id:String,kind:String)->bool:
	var queue:Array=world.state.terminal.queues[kind]
	if queue.is_empty() or queue[0]!=id:return false
	var actor:Dictionary=world.state.agents[id]
	if not actor.alive or world._hands(actor)==0 or not _near_terminal(world,actor):return false
	for loan in world.state.terminal.loans.values():
		if loan.actor==id:return false
	for item in world.state.items.values():
		if item.kind==kind and item.container=="terminal" and str(item.holder).is_empty():
			item.holder=id;item.container="";actor.inventory.append(item.id)
			world.state.terminal.loans[item.id]={"actor":id,"deadline":float(world.state.minute)+float(world.state.terminal.slot_minutes),"kind":kind,"overdue":false}
			queue.pop_front()
			world._personal(id,{"channel":"terminal","text":"Выдано общее оборудование: "+str(item.label),"source":"issued_item"})
			return true
	return false

static func _shop(world:Object,id:String,action:Dictionary,resolved:Dictionary)->Dictionary:
	var actor:Dictionary=world.state.agents[id]
	var shop:Dictionary={}
	for prop in world.state.geometry.props:
		if prop.kind=="shop":shop=prop;break
	if shop.is_empty() or Spatial.point(actor).distance_to(Spatial.point(shop))>2.5 or not Spatial.clear_line(Spatial.point(actor),Spatial.point(shop),world.state.geometry,0.0,str(shop.id),true):return world._result(false,"Нужно подойти к доступной стороне прилавка магазина.")
	if world._hands(actor)==0:return world._result(false,"Нельзя выполнить сделку руками.")
	if action.type=="buy":
		if resolved.get("category")!="prop" or resolved.get("id")!=shop.id:return world._result(false,"Нужно выбрать видимый магазин.")
		if not Spatial.visible(actor,Spatial.point(shop),world.state.geometry,str(shop.id),2.5):return world._result(false,"Прилавок магазина больше не виден.")
		var kind:String=str(action.get("kind","ration"))
		if not world.state.economy.prices.has(kind):return world._result(false,"Такого товара нет в ассортименте.")
		var price:=int(world.state.economy.prices[kind])
		if int(world.state.economy.shop_stock.get(kind,0))<=0 or int(actor.tokens)<price:return world._result(false,"Не хватает товара или жетонов.")
		var item:Dictionary={}
		for stored in world.state.items.values():
			if stored.kind==kind and stored.container=="shop":item=stored;break
		actor.tokens=int(actor.tokens)-price;world.state.economy.shop_stock[kind]=int(world.state.economy.shop_stock[kind])-1
		if item.is_empty():item=world._new_item(kind,{"ration":"Паёк","medkit":"Аптечка","splint":"Шина","camera":"Фотоаппарат","knife":"Нож"}.get(kind,kind),actor.position,id,id)
		else:item.holder=id;item.owner=id;item.container="";actor.inventory.append(item.id)
		return world._result(true,"Куплен предмет за %d жетонов."%price,{"item":item.id})
	var item:Dictionary=world._inventory_item(id,int(action.slot))
	if item.is_empty() or not world.state.economy.prices.has(item.kind) or world.state.terminal.loans.has(item.id):return world._result(false,"Этот предмет нельзя продать магазину.")
	var price:=maxi(1,floori(float(world.state.economy.prices[item.kind])*0.5))
	actor.inventory.erase(item.id);item.holder="";item.owner="shop";item.container="shop";item.position=shop.center.duplicate()
	actor.tokens=int(actor.tokens)+price;world.state.economy.shop_stock[item.kind]=int(world.state.economy.shop_stock.get(item.kind,0))+1
	return world._result(true,"Предмет продан за %d жетонов."%price)

static func _offer(world:Object,id:String,action:Dictionary,resolved:Dictionary)->Dictionary:
	var actor:Dictionary=world.state.agents[id]
	if action.type=="offer":
		if resolved.get("category")!="agent" or not world._reachable(id,resolved):return world._result(false,"Контрагент вне досягаемости.")
		var other:Dictionary=world._entity(resolved)
		var item_id:=""
		if action.has("slot"):
			var item:Dictionary=world._inventory_item(id,int(action.slot))
			if item.is_empty():return world._result(false,"Предложенного предмета нет.")
			item_id=item.id
		var tokens:=int(action.get("tokens",0));var requested:=int(action.get("request_tokens",0))
		if tokens>int(actor.tokens):return world._result(false,"Недостаточно жетонов для предложения.")
		if item_id.is_empty() and tokens==0 and str(action.get("promise","")).is_empty():return world._result(false,"Пустое предложение.")
		world._introduce(id,str(other.id));world._introduce(str(other.id),id)
		var offer_id:="offer_%d"%int(world.state.economy.next_offer)
		world.state.economy.next_offer=int(world.state.economy.next_offer)+1
		var offer:Dictionary={"id":offer_id,"from":id,"to":other.id,"item":item_id,"tokens":tokens,"request_tokens":requested,"promise":str(action.get("promise","")),"deadline":float(world.state.minute)+float(action.get("deadline",120.0)),"created":float(world.state.minute),"status":"proposed"}
		world.state.economy.offers[offer_id]=offer
		for participant in [id,str(other.id)]:
			if not world.state.agents[participant].has("offer_refs"):world.state.agents[participant].offer_refs={}
			var local:="o%d"%world.state.agents[participant].offer_refs.size()
			world.state.agents[participant].offer_refs[local]=offer_id
			world._personal(participant,{"channel":"offer","ref":local,"from":actor.name,"to":other.name,"item":world.state.items.get(item_id,{}).get("label",""),"tokens":tokens,"request_tokens":requested,"promise":offer.promise,"deadline":offer.deadline,"source":"personal_negotiation"})
		return world._result(true,"Предложение передано; имущество пока не перемещено.")
	var offer_id:String=actor.get("offer_refs",{}).get(str(action.get("offer","")),"")
	var offer:Dictionary=world.state.economy.offers.get(offer_id,{})
	if offer.is_empty():return world._result(false,"Предложение неизвестно персонажу.")
	if action.type=="fulfil_promise":
		if offer.from!=id or offer.status!="accepted":return world._result(false,"Нет принятого обязательства для заявления.")
		offer.status="claimed"
		world._personal(str(offer.to),{"channel":"promise","text":"Контрагент заявил о выполнении. Можно проверить и подтвердить.","source":"counterparty_claim"})
		return world._result(true,"Заявлено о выполнении; нужно подтверждение контрагента.")
	if offer.to!=id:return world._result(false,"Подтвердить может адресат.")
	if offer.status=="claimed":offer.status="fulfilled";world._relation(id,str(offer.from),8.0,"Подтвердил исполнение обещания.");return world._result(true,"Исполнение подтверждено контрагентом.")
	if offer.status!="proposed" or float(world.state.minute)>float(offer.deadline):return world._result(false,"Предложение завершено или истекло.")
	var sender:Dictionary=world.state.agents[offer.from]
	if not sender.alive or sender.sleeping or sender.unconscious:return world._result(false,"Контрагент не может сейчас участвовать в обмене.")
	if Spatial.point(actor).distance_to(Spatial.point(sender))>world.REACH or not Spatial.clear_line(Spatial.point(actor),Spatial.point(sender),world.state.geometry,0.0,"",true):return world._result(false,"Для обмена нужна доступная встреча.")
	if world._hands(actor)==0 or world._hands(sender)==0:return world._result(false,"Сторона не может передавать предметы.")
	if int(sender.tokens)<int(offer.tokens) or int(actor.tokens)<int(offer.request_tokens):return world._result(false,"Баланс изменился; сделка целиком отклонена.")
	if not str(offer.item).is_empty() and (not world.state.items.has(offer.item) or not sender.inventory.has(offer.item) or world.state.items[offer.item].holder!=sender.id):return world._result(false,"Предмет уже отсутствует; сделка целиком отклонена.")
	sender.tokens=int(sender.tokens)-int(offer.tokens)+int(offer.request_tokens);actor.tokens=int(actor.tokens)+int(offer.tokens)-int(offer.request_tokens)
	if not str(offer.item).is_empty():sender.inventory.erase(offer.item);actor.inventory.append(offer.item);world.state.items[offer.item].holder=id;world.state.items[offer.item].owner=id
	offer.status="accepted" if not str(offer.promise).is_empty() else "completed"
	world._relation(id,str(sender.id),4.0,"Выполнен реальный обмен.")
	return world._result(true,"Обмен выполнен атомарно; будущее обещание учтено отдельно.")

static func advance(world:Object,_minutes:float)->void:
	for offer in world.state.economy.offers.values():
		if offer.status in ["proposed","accepted","claimed"] and float(world.state.minute)>float(offer.deadline):
			var promised:bool=offer.status in ["accepted","claimed"]
			offer.status="expired"
			if promised:world._relation(str(offer.to),str(offer.from),-10.0,"Истёк срок принятого обещания.");world._personal(str(offer.to),{"channel":"promise","text":"Истёк срок обещания без подтверждения.","source":"own_agreement"})
	for loan in world.state.terminal.loans.values():
		if not loan.overdue and float(world.state.minute)>float(loan.deadline):loan.overdue=true;world._personal(str(loan.actor),{"channel":"terminal","text":"Срок устройства истёк; новая выдача заблокирована до возврата.","source":"equipment_deadline"})
	for kind in ["camera","phone"]:
		var queue:Array=world.state.terminal.queues[kind]
		# A dead participant cannot collect equipment; keeping that obsolete head
		# would permanently block every living participant behind them.
		while not queue.is_empty() and (not world.state.agents.has(str(queue[0])) or not world.state.agents[str(queue[0])].alive):queue.pop_front()
		if not queue.is_empty():_issue(world,str(queue[0]),kind)
