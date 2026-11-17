extends RefCounted
## Offline characters act from their own briefing, conversations, visible objects
## and public plans they personally read. This policy has no simulation reference.

static func decide(p:Dictionary,c:Dictionary,view:Array,last_action:Dictionary,language:String)->Dictionary:
	var minute:=float(c.minute)
	var own:Dictionary=c.self_state
	if own.body.blind or not own.alive or own.unconscious or own.sleeping or not own.busy.is_empty():return {}
	for entry in c.personal_results:
		var text:=str(entry.get("text",""))
		match entry.get("channel"):
			"briefing":
				if text.contains("ограниченными пайками"):p.episode="block"
				elif text.contains("деньги и доступ"):p.episode="house"
				elif text.contains("перед штормом"):p.episode="station"
				p.stock_role=text.contains("полномочия выдачи")
				p.net_role=text.contains("полномочия сети")
			"floor_plan":
				if float(entry.minute)>float(p.get("chart_time",-1)):
					p.chart_time=entry.minute;p.place=entry.title
					for mark in entry.get("entries",[]):p["sign/"+str(mark.title)]=str(mark.ref)
			"document":
				if text.contains("ДЕЙСТВУЮЩАЯ СХЕМА"):p.order=true
				if text.contains("АРХИВ") and text.contains("северного"):p.old_order=true
			"announcement":
				if text.contains("Шторм прервал"):p.outage=true
				if text.contains("Начался сбор"):p.assembly=true
				if text.contains("цена пайка") and text.contains("5"):p.price=5
				if text.contains("цена пайка") and text.contains("три"):p.price=3
	for speech in c.heard:
		var report:=str(speech.text)
		if report.contains("по действующей схеме") or report.contains("current assembly notice"):p.heard_order=true
	if not p.has("episode"):return {}
	if last_action.get("type")=="follow_route":
		if c.last_result.get("ok",false):
			p.place=p.get("route_goal","");p.scans=0
		else:
			p.place="";p.detour=true
	var person:=_near(view,"agent")
	var board:=_near(view,"noticeboard")
	var ration:=_inventory(c.inventory,"ration")
	if c.last_result.get("type")=="consume" and c.last_result.get("ok",false):p.ate=true;p.last_meal=minute
	if c.last_result.get("type")=="request_ration" and not c.last_result.get("ok",true):
		if str(c.last_result.message).contains("уже получен"):p.quota=true
	if c.last_result.get("type")=="request_ration" and c.last_result.get("ok",false):p.quota=true
	if c.last_result.get("type")=="give" and c.last_result.get("ok",false):p.last_share=minute
	if c.last_result.get("type")=="transfer_tokens" and c.last_result.get("ok",false):p.last_donation=minute
	if c.last_result.get("type")=="buy" and not c.last_result.get("ok",true):p.price=5
	if c.last_result.get("type")=="interact" and str(c.last_result.get("message","")).contains("Связь восстановлена"):p.repaired=true
	if last_action.get("type")=="move_to" and not c.last_result.get("ok",true):
		p.avoid_attempts=int(p.get("avoid_attempts",0))+1
		if int(p.avoid_attempts)%3==1:return {"type":"turn","degrees":65}
		return {"type":"move","forward":0.8,"right":1.1 if int(p.avoid_attempts)%2==0 else -1.1}
	if p.get("detour",false):
		p.detour=false
		return {"type":"move","forward":1.0,"right":1.1}
	var role:=str(p.episode)
	var lang_en:=language=="en"
	var stock_place:={"block":"Выдача пайков","house":"Продуктовая лавка","station":"Склад экспедиции"}[role] as String
	if not p.has("welcomed"):
		p.welcomed=true
		var greeting:Dictionary={"block":["Узнаю правила выдачи. Кто уже проверял терминал?","I'll check the ration rules. Has anyone tried the terminal?"],"house":["Я зайду в лавку. На всех еды хватит, если поможем с оплатой.","I'm going to the shop. Let's help anyone who can't afford a meal."],"station":["По сводке, схемы сбора расходятся. Сверю их у узла связи.","There are two assembly notices. I'll check them at communications."]}
		if role=="house" and int(own.tokens)<3:return _say(p,"I'm short of tokens for a ration. I'll ask at the shop." if lang_en else "Не хватает жетонов на паёк. Попрошу помощи у лавки.",minute)
		if role=="station" and own.body.left_leg!="healthy":return _say(p,"My leg hurts. I'll check where we should assemble." if lang_en else "Болит нога. Нужно узнать, где собирается группа.",minute)
		if role=="station" and p.get("net_role",false):return _say(p,"I'll check the station bulletin and the communications console." if lang_en else "Проверю действующую схему и консоль связи.",minute)
		if role=="block" and p.get("stock_role",false):return _say(p,"I have the stockroom key. I'll check the supply office." if lang_en else "У меня есть право открыть резерв. Проверю выдачу.",minute)
		return _say(p,greeting[role][int(lang_en)],minute)
	if ration>=0 and (not p.get("ate",false) or (float(own.needs.hunger)>30 and minute-float(p.get("last_meal",0))>=180)):
		return {"type":"consume","slot":ration}
	if not p.has("chart_time"):
		return _inspect(p,board)
	if role=="station" and (p.get("assembly",false) or minute>=480) and (p.get("order",false) or p.get("heard_order",false)):
		if p.get("place","")!="Южный сборный пункт":return _route(p,"Южный сборный пункт")
		if minute-float(p.get("last_speech",-200))>65:return _say(p,"I'm at the southern assembly area." if lang_en else "Я на южном сборном пункте.",minute)
		return {"type":"rest","minutes":18.0}
	if not person.is_empty() and float(person.distance)<2.0 and minute-float(p.get("last_contact",-30))>32 and str(person.label).begins_with("Человек"):
		p.last_contact=minute
		return _target(person,{"type":"interact"})
	if role=="house" and int(own.tokens)>=8 and minute-float(p.get("last_donation",-100))>45 and not person.is_empty():
		for speech in c.heard:
			if minute-float(speech.minute)>30:continue
			if (str(speech.text).contains("Не хватает жетонов") or str(speech.text).contains("short of tokens")):
				for candidate in view:
					if candidate.kind=="agent" and (candidate.label==speech.speaker or (speech.speaker=="Голос рядом" and absf(float(candidate.bearing)-float(speech.bearing))<30)):
						return _target(candidate,{"type":"transfer_tokens","tokens":5})
	if role=="station" and p.get("order",false) and not person.is_empty() and minute-float(p.get("last_speech",-100))>28:
		return _say(p,"The current assembly notice says the southern point opens at 16:00." if lang_en else "Сбор по действующей схеме у южного пункта с 16:00.",minute)
	if role=="station" and p.get("net_role",false) and p.get("outage",false) and not p.get("repaired",false):
		if p.get("place","")!="Узел связи":return _route(p,"Узел связи")
		return _inspect(p,_near(view,"console"))
	if role=="station" and own.body.left_leg=="injured" and p.get("ate",false) and minute<340 and not p.get("treated",false):
		var splint:=_inventory(c.inventory,"splint")
		if splint>=0:
			p.treated=true
			return {"type":"treat","slot":splint,"limb":"left_leg"}
		if p.get("place","")!="Медицинский блок":return _route(p,"Медицинский блок")
		var brace:=_near(view,"splint")
		return _scan(p) if brace.is_empty() else _target(brace,{"type":"take"})
	if role=="station" and not p.get("order",false) and (minute>260 or p.get("ate",false) or p.get("net_role",false)):
		if p.get("place","")!="Узел связи":return _route(p,"Узел связи")
		return _inspect(p,board)
	if role=="house" and int(own.tokens)<int(p.get("price",3)) and not p.get("ate",false):
		if p.get("place","")!=stock_place:return _route(p,stock_place)
		if minute-float(p.get("last_speech",-100))>22:return _say(p,"I'm short of tokens for a ration. Could someone help?" if lang_en else "Не хватает жетонов на паёк. Кто может помочь?",minute)
		if not person.is_empty() and person.distance>1.5:return {"type":"move_to","target":person.ref}
		return _scan(p)
	if not p.get("ate",false):
		var loose:=_near(view,"ration")
		if not loose.is_empty():return _target(loose,{"type":"take"})
		if p.get("place","")!=stock_place:return _route(p,stock_place)
		var service:=_near(view,"shop" if role=="house" else "terminal")
		if not service.is_empty():
			if role=="house":return _target(service,{"type":"buy","kind":"ration"},2.35)
			if not p.get("quota",false):return {"type":"request_ration"} if float(service.distance)<=1.9 else {"type":"move_to","target":service.ref}
		return _scan(p)
	if role=="block" and p.get("stock_role",false) and minute<500 and minute-float(p.get("last_share",-200))>45:
		if ration>=0:
			for candidate in view:
				if candidate.kind=="agent" and candidate.label!=p.get("given_to",""):
					if float(candidate.distance)<=1.4:p.given_to=candidate.label
					return _target(candidate,{"type":"give","slot":ration})
			if p.get("place","")!=stock_place:return _route(p,stock_place)
			return _scan(p)
		if p.get("place","")!="Резерв блока":return _route(p,"Резерв блока")
		var loose:=_near(view,"ration")
		if not loose.is_empty():return _target(loose,{"type":"take"})
		if minute-float(p.get("opened",-100))<20:return _scan(p)
		var cabinet:=_near(view,"wardrobe","Резервный шкаф")
		if cabinet.is_empty():return _scan(p)
		if not p.get("unlocked",false):
			if float(cabinet.distance)<=1.4:p.unlocked=true
			return _target(cabinet,{"type":"unlock"})
		if float(cabinet.distance)<=1.4:p.opened=minute
		return _target(cabinet,{"type":"open"})
	if p.get("place","")==stock_place and p.get("ate",false) and not p.get("stock_role",false) and (role=="block" or (role=="house" and int(own.tokens)<8)):
		return _route(p,"Общий зал" if role=="block" else "Зал собраний")
	if role=="house" and int(own.tokens)>=8 and p.get("place","")!=stock_place:return _route(p,stock_place)
	if role=="station" and p.get("order",false) and minute>=420 and p.get("place","")!="Северный шлюз":return _route(p,"Северный шлюз")
	if float(own.needs.fatigue)>65:return {"type":"rest","minutes":20}
	if minute-float(p.get("last_speech",-100))>48 and not person.is_empty():
		return _say(p,"I've eaten. Does anyone still need a meal?" if lang_en else "Я уже поел. Кому ещё нужен паёк?",minute)
	return _scan(p) if person.is_empty() else {"type":"wait","minutes":8.0}

static func _inspect(p:Dictionary,thing:Dictionary)->Dictionary:
	return _scan(p) if thing.is_empty() else _target(thing,{"type":"interact"})

static func _scan(p:Dictionary)->Dictionary:
	p.scans=int(p.get("scans",0))+1
	if int(p.scans)%5==0:return {"type":"move","forward":1.15,"right":0.7}
	return {"type":"turn","degrees":78}

static func _target(thing:Dictionary,operation:Dictionary,reach:float=1.4)->Dictionary:
	if float(thing.distance)>reach:return {"type":"move_to","target":thing.ref}
	operation["target"]=thing.ref
	return operation

static func _route(p:Dictionary,label:String)->Dictionary:
	if not p.has("sign/"+label):return _scan(p)
	p.route_goal=label
	return {"type":"follow_route","route":p["sign/"+label]}

static func _near(view:Array,kind:String,label:String="")->Dictionary:
	var found:Dictionary={}
	for entry in view:
		if entry.kind==kind and (label=="" or entry.label==label) and (found.is_empty() or entry.distance<found.distance):found=entry
	return found

static func _inventory(items:Array,kind:String)->int:
	for item in items:
		if item.kind==kind:return int(item.slot)
	return -1

static func _say(p:Dictionary,line:String,minute:float)->Dictionary:
	p.last_speech=minute
	return {"type":"speak","text":line}
