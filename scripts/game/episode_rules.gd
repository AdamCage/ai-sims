extends RefCounted
## Authored circumstances, not authored decisions. Only executed facts score an ending.
const Spatial=preload("res://scripts/game/spatial_rules.gd")
const IDS=["block_shift","common_house","station_exit"]
const TITLES={"block_shift":"До следующей выдачи","common_house":"Цена общего дома","station_exit":"Два сообщения"}
const TITLES_EN={"block_shift":"Until the next ration","common_house":"The price of a shared home","station_exit":"Two messages"}
const NAMES=["Мира","Борис","Кора","Дани","Эли","Фая","Глеб","Хана","Иван","Юна","Кай","Лена","Макс","Ника","Омар","Пия","Квин","Рина","Свен","Тара"]
const GOALS=["Познакомиться с людьми, узнать их нужды и предложить взаимопомощь.","Лично проверить правила выдачи и помочь распределить ограниченные запасы.","Найти узел связи, проверить важные сведения и поддерживать доступную связь.","Найти медицинские средства, осмотреть нуждающихся и предложить помощь.","Изучить местные документы, сравнивать независимые источники и сохранять находки.","Знакомиться лично, передавать проверенные новости и помогать договариваться.","Проверить ассортимент магазина, искать честные сделки и беречь собственные средства.","Осмотреть новое место, найти пищу, познакомиться и попросить помощь при необходимости."]

static func is_episode(id:String)->bool:return id in IDS

static func prepare(world:Dictionary)->void:
	var id:String=world.scenario
	var descriptions:Dictionary={"block_shift":"До вечера группа остаётся с ограниченными пайками. Найдите правила и резерв; кому достанутся запасы, решают сами люди.","common_house":"Еды достаточно, но деньги и доступ распределены неравномерно. Покупки, помощь и договорённости определят, каким станет общий дом.","station_exit":"К вечеру станцию закрывают перед штормом. Старое и новое сообщения о сборе расходятся; группе предстоит проверить сведения и помочь пострадавшим."}
	world["scenario_description"]=descriptions[id]
	world["scenario_state"]={"id":id,"title":TITLES[id],"title_en":TITLES_EN[id],"description":descriptions[id],"phase":1,"phase_title":"Начало смены","current_problem":"Осмотритесь, выберите человека и следите за его намерениями и последствиями.","deadline":720.0,"display_start_minute":480.0,"completed":false,"outcome":{},"debrief":[],"metrics":{"food_received":{},"food_consumed":{},"food_help":{},"verified_sources":{},"interventions":0},"interventions":[{"id":"announcement","title":"Публичное объявление","description":"Передать сообщение от наблюдателя через публичную связь.","used":false},{"id":"reserve","title":"Открыть предусмотренный резерв","description":"Открыть физический запас или заранее созданный фонд помощи.","used":false},{"id":"policy","title":"Изменить внешние условия","description":"Лимит выдачи, цена или резервная связь: люди сами решат, как действовать.","used":false}],"triggered":[],"initial_poor":[],"injured":[]}
	var descriptions_en:Dictionary={
		"block_shift":"The next supply is due at the end of the shift. Watch who checks the ration rules, finds the reserve and shares food.",
		"common_house":"There is enough food, but some residents cannot afford it. Follow their purchases, help and agreements.",
		"station_exit":"A storm will close the station this evening. The assembly notices disagree and one resident needs help walking."
	}
	world.scenario_state["description_en"]=descriptions_en[id]
	world.scenario_state["moments"]={}
	var count:int=world.agents.size()
	for key in world.items.keys():
		if world.items[key].kind=="ration":world.items.erase(key)
	var anchors:Array={
		"block_shift":["common","supply","reserve","medical","common","supply","arrival","dining"],
		"common_house":["common","shop","comms","medical","common","shop","shop","common"],
		"station_exit":["common","supply","comms","medical","comms","arrival","supply","arrival"]
	}[id]
	for index in count:
		var actor:Dictionary=world.agents.values()[index]
		actor.name=NAMES[index]
		actor.profile.goal=GOALS[index%8]
		actor.profile.foundation=GOALS[index%8]+" Ценит "+["сотрудничество","порядок и личную безопасность","независимую проверку","заботу о людях","знания и личные границы","мирные договорённости","свободу обмена","надёжность и поддержку"][index%8]+"."
		actor.roles=[]
		if index==1:actor.roles.append("terminal_admin")
		if index==2:actor.roles.append("network_admin")
		var anchor:Array=world.geometry.zones.get(anchors[index%8],world.geometry.zones.spawn)
		_place_actor(actor,anchor,world,index)
		actor.needs.hunger=50.0+float(index%4)*8.0
		actor.needs.fatigue=15.0+float(index%3)*15.0
		actor.personal_results.append({"channel":"briefing","text":descriptions[id]+" "+("У вас есть полномочия выдачи; закрытый резерв открывается вашим правом." if index==1 else ("У вас есть полномочия сети; управление доступно у физической консоли связи." if index==2 else "Вы знаете только собственный опыт и доступные вам источники.")),"source":"scenario_briefing","minute":0.0})
		for item_id in actor.inventory:world.items[item_id].position=actor.position.duplicate()
	world.terminal.stock=count if id=="block_shift" else (0 if id=="common_house" else ceili(count*1.5))
	world.economy.shop_stock.ration=ceili(count*1.5) if id=="common_house" else 0
	world.economy.prices.ration=3
	var reserve_position:Array=world.geometry.zones.reserve.duplicate()
	for prop in world.geometry.props:
		if prop.id=="episode_reserve":
			prop["label"]="Резервный шкаф"
			prop.locked=id!="common_house"
			prop.open=false
			reserve_position=[float(prop.center[0]),float(prop.center[1])+float(prop.size[1])*0.5+0.35]
	for index in ceili(count*0.5):
		var key:String="episode_ration_%02d"%index
		world.items[key]={"id":key,"label":"Запас общего резерва","kind":"ration","position":reserve_position.duplicate(),"holder":"","owner":"community","container":"episode_reserve","surface_height":0.0,"quantity":1}
	if id=="common_house":
		for index in count:
			var actor:Dictionary=world.agents.values()[index]
			actor.tokens=[18,15,12,8,3,0,0,0][index%8]
			if count<6 and index==count-1:actor.tokens=0
			if int(actor.tokens)<3:world.scenario_state.initial_poor.append(actor.id)
		world.scenario_state["reserve_fund"]=5*world.scenario_state.initial_poor.size()
	elif id=="station_exit":
		var injured:Dictionary=world.agents.values()[-1]
		injured.body.left_leg="injured";injured.health=80.0
		world.scenario_state.injured.append(injured.id)
		for door in world.geometry.doors:
			if str(door.id).begins_with("evacuation_"):door.open=false;door.locked=true
		for kind in ["medkit","splint"]:
			var key:String="episode_reserve_"+kind
			world.items[key]={"id":key,"label":"Резервная аптечка" if kind=="medkit" else "Резервная шина","kind":kind,"position":reserve_position.duplicate(),"holder":"","owner":"community","container":"episode_reserve","surface_height":0.0,"quantity":1}
		injured.personal_results.append({"channel":"body","text":"У вас травмирована нога; боль мешает ходьбе. Можно попросить лечение или помощь.","source":"own_body","minute":0.0})
		for actor in world.agents.values():actor.profile.goal+=" До конца смены найти действующее место сбора, проверить объявление лично и добраться туда; при необходимости просить помощь."
	_set_documents(world)
	var cards:Array=world.scenario_state.interventions
	cards[1].title="Открыть резерв пайков" if id=="block_shift" else ("Открыть фонд помощи" if id=="common_house" else "Открыть аварийный проход")
	cards[2].title="Увеличить лимит выдачи" if id=="block_shift" else ("Зафиксировать цену" if id=="common_house" else "Включить резервную связь")
	cards[0]["title_en"]="Make an announcement"
	cards[0]["description_en"]="Broadcast a message to everyone able to hear it."
	cards[1]["title_en"]={"block_shift":"Open the food reserve","common_house":"Release the relief fund","station_exit":"Open the emergency passage"}[id]
	cards[1]["description_en"]={"block_shift":"Unlock the physical food cabinet.","common_house":"Release five tokens per resident who started without enough for a ration.","station_exit":"Open the assembly area early and unlock medical supplies."}[id]
	cards[2]["title_en"]={"block_shift":"Raise the ration limit","common_house":"Freeze food prices","station_exit":"Switch on backup communications"}[id]
	cards[2]["description_en"]={"block_shift":"Allow two rations per person while supplies last.","common_house":"Hold the price at three tokens.","station_exit":"Restore the station network."}[id]
	world.objectives=[{"id":"episode_safe","title":"Проследить судьбу группы до 20:00","complete":false},{"id":"episode_help","title":"Помощь должна реально дойти до нуждающихся","complete":false},{"id":"episode_sources","title":"Персонажи лично читают действующие правила","complete":false}]
	if id=="station_exit":world.objectives[1].title="Пострадавший добрался до сборного пункта"
	if id=="common_house":world.objectives[1].title="Каждый житель без денег получил помощь с питанием"
	_update_phase(world)

static func _place_actor(actor:Dictionary,anchor:Array,world:Dictionary,index:int)->void:
	var center:=Vector2(anchor[0],anchor[1])
	var rotation:float=deg_to_rad(float(posmod(int(world.seed)*11+index*127,360)))
	for radius in [3.1,2.35,1.65,4.0]:
		for step in 24:
			var offset:=Vector2.from_angle(rotation+step*TAU/24.0)*float(radius)
			var p:=center+offset
			if Spatial.walkable(p,world.geometry,world.agents,str(actor.id)) and Spatial.clear_line(p,center,world.geometry,0.0,"",true):
				actor.position=[p.x,p.y]
				actor.heading=rad_to_deg(atan2(offset.x,offset.y))
				return

static func _set_documents(world:Dictionary)->void:
	for prop in world.geometry.props:
		if prop.kind!="noticeboard":continue
		if str(prop.id).begins_with("supply_"):
			prop.document="Действующий регламент выдачи: один личный паёк в сутки. Запасы конечны; чтение уведомления не меняет реестр. Резерв доступен уполномоченному снабжения."
		if world.scenario=="block_shift" and prop.id=="arrival_notice":prop.document="АРХИВ, план поставки: дополнительная выдача сегодня после 14:00. Время уточняется; это объявление не изменяет действующий реестр."
		if world.scenario=="common_house" and str(prop.id).begins_with("shop_"):prop.document="Действующий прейскурант: паёк — 3 жетона. Личные деньги можно передавать добровольно; наличие магазина не гарантирует каждому покупку."
		if world.scenario=="station_exit":
			if str(prop.id).begins_with("arrival_"):prop.document="АРХИВ, 06:00: сбор у северного шлюза. Дежурный хранит подписанный действующий лист у узла связи."
			if prop.id in ["comms_notice","evacuation_notice"]:prop.document="ДЕЙСТВУЮЩАЯ СХЕМА: сбор у южного сборного пункта до 20:00. С 16:00 пункт принимает группу. Помогите людям с травмами."
	world.network.pages.welcome.text="Публичные сведения: "+str(world.scenario_state.description)+" Действующие правила проверяются на местных табличках и терминалах."

static func advance(sim:Object)->void:
	if not sim.state.has("scenario_state"):return
	var story:Dictionary=sim.state.scenario_state
	if story.completed:return
	var minute:float=sim.state.minute
	_update_phase(sim.state)
	if minute>=180.0 and not story.triggered.has("crisis"):
		story.triggered.append("crisis")
		var message:String="Поставка задержана до конца смены. Регламент выдачи и старое объявление могут расходиться; проверяйте местный реестр."
		if story.id=="common_house":
			var price:int=3 if story.triggered.has("price_frozen") else 5
			sim.state.economy.prices.ration=price;message="Поставка перенесена. Действующая цена пайка: %d жетонов. Старый прочитанный прейскурант остаётся прошлым опытом."%price
			for prop in sim.state.geometry.props:
				if prop.id=="shop_notice":prop.document="Действующий прейскурант, 11:00: паёк — %d жетонов. Проверяйте актуальное состояние лично."%price
		elif story.id=="station_exit":
			sim.state.network.online=story.triggered.has("backup_network")
			message="Шторм прервал основную связь. Локальные записи и разговоры доступны; узел связи может восстановить уполномоченный участник." if not sim.state.network.online else "Шторм прервал основную связь; включённый наблюдателем резерв продолжает работать."
		_public_notice(sim,message,"external_crisis")
	if minute>=480.0 and not story.triggered.has("resolution"):
		story.triggered.append("resolution")
		if story.id=="station_exit":
			for door in sim.state.geometry.doors:
				if str(door.id).begins_with("evacuation_"):door.locked=false;door.open=true
		_public_notice(sim,"До конца смены осталось четыре часа. Проверьте положение группы и последствия договорённостей." if story.id!="station_exit" else "Начался сбор группы. Уточните действующий маршрут по местной схеме и помогите раненым.","external_notice")
	_update_objectives(sim.state)
	if minute>=float(story.deadline):_finish(sim)

static func _public_notice(sim:Object,text:String,source:String)->void:
	# An explicit audible announcement; it does not rewrite belief or old experience.
	for actor in sim.state.agents.values():
		if actor.alive and not actor.unconscious and not actor.sleeping:sim._personal(str(actor.id),{"channel":"announcement","text":text,"source":source})
	sim._event("world","story_event",true,text,{"source":source})

static func _update_phase(world:Dictionary)->void:
	var story:Dictionary=world.scenario_state
	story.phase=1 if float(world.minute)<180.0 else (2 if float(world.minute)<480.0 else 3)
	var phases:Dictionary={"block_shift":[["Понять правила","Кому доступны пайки, где резерв и кто ещё не получил помощь?"],["Поставка задержана","Запасов до конца смены не прибавится. Наблюдайте распределение и проверку сведений."],["Общее решение","Успеет ли помощь дойти до голодных? Проследите последствия договорённостей."]],"common_house":[["Каждый со своим","Деньги распределены неравномерно. Люди могут покупать, обмениваться и просить помощь."],["Новая цена","Цена изменилась. Дойдут ли действующие сведения и помощь до людей без денег?"],["Кому досталась помощь","Какие обещания исполнены, кто поел и у кого остались средства?"]],"station_exit":[["Подготовка","Старая и новая схемы сбора расходятся. Есть человек с травмой."],["Связь пропала","Локальные документы, разговоры и помощь работают без сети."],["Сбор","Южный пункт открыт. Доберётся ли туда вся группа вместе с пострадавшим?"]]}
	story.phase_title=phases[story.id][int(story.phase)-1][0]
	story.current_problem=phases[story.id][int(story.phase)-1][1]
	var phases_en:Dictionary={
		"block_shift":[["Check the rules","Who can collect food, where is the reserve, and who needs help?"],["Delivery delayed","Nothing more is coming before nightfall. Follow the remaining rations."],["A shared decision","Will food reach the people who need it before the shift ends?"]],
		"common_house":[["Unequal means","Some residents have enough money and others need help."],["A new price","Will everyone learn the new price and find a meal?"],["Who received help?","See whose promises held, who ate and who still has money."]],
		"station_exit":[["Preparations","The assembly notices disagree. One resident has an injured leg."],["Communications interrupted","Local notices and face-to-face conversations still work during the outage."],["Assembly","The southern assembly area is open. Can the whole group reach it before nightfall?"]]
	}
	story["phase_title_en"]=phases_en[story.id][int(story.phase)-1][0]
	story["current_problem_en"]=phases_en[story.id][int(story.phase)-1][1]

static func record_event(world:Dictionary,event:Dictionary)->void:
	if not world.has("scenario_state") or not event.ok:return
	var metrics:Dictionary=world.scenario_state.metrics
	var actor:String=event.actor;var details:Dictionary=event.details
	if event.type=="consume" and details.get("kind")=="ration":
		metrics.food_consumed[actor]=int(metrics.food_consumed.get(actor,0))+1
		if str(details.get("given_by",""))!="" and details.given_by!=actor:metrics.food_help[actor]=int(metrics.food_help.get(actor,0))+1
		if str(details.get("given_by",""))!="" and world.agents.has(details.given_by):
			var giver:String=str(world.agents[details.given_by].name)
			var eater:String=str(world.agents[actor].name)
			_moment(world,"shared_meal","%s съедает паёк, полученный от %s."%[eater,giver],"%s ate the ration given by %s."%[eater,giver])
	if event.type=="give" and details.get("kind")=="ration":
		var recipient:String=str(details.get("recipient",""))
		metrics.food_received[recipient]=int(metrics.food_received.get(recipient,0))+1
	if event.type=="help" and details.get("fed",false):metrics.food_help[str(details.recipient)]=int(metrics.food_help.get(str(details.recipient),0))+1
	if event.type=="request_ration" and str(event.message).begins_with("Выдан"):metrics.food_received[actor]=int(metrics.food_received.get(actor,0))+1
	if world.scenario_state.id=="common_house":
		if not metrics.has("funded"):metrics.funded={}
		if event.type=="transfer_tokens" and details.has("recipient"):
			var recipient:String=str(details.recipient)
			metrics.funded[recipient]=int(metrics.funded.get(recipient,0))+int(details.tokens)
		# A donation counts once a ration actually costs more than the resident's own funds.
		if event.type=="buy" and details.get("kind")=="ration" and int(metrics.funded.get(actor,0))>int(world.agents[actor].tokens):
			metrics.food_help[actor]=int(metrics.food_help.get(actor,0))+1
			var buyer:String=str(world.agents[actor].name)
			_moment(world,"funded_meal",buyer+" покупает еду благодаря переданным жетонам.",buyer+" bought food with donated tokens.")
		for recipient in metrics.funded:
			metrics.funded[recipient]=mini(int(metrics.funded[recipient]),int(world.agents[recipient].tokens))

	if details.get("restored_network",false):
		var name:String=str(world.agents[actor].name)
		_moment(world,"connection",name+" восстанавливает сеть на консоли.",name+" restored the network at the communications console.")

static func _moment(world:Dictionary,key:String,ru:String,en:String)->void:
	var story:Dictionary=world.scenario_state
	if not story.has("moments"):story.moments={}
	if not story.moments.has(key):story.moments[key]={"minute":world.minute,"ru":ru,"en":en}

static func record_source(world:Dictionary,actor:String,entry:Dictionary)->void:
	if not world.has("scenario_state"):return
	var story:Dictionary=world.scenario_state
	var valid:Dictionary={"block_shift":["supply_notice"],"common_house":["shop_notice"],"station_exit":["comms_notice","evacuation_notice"]}
	var local_read:bool=entry.get("source","")=="physical_notice" and entry.get("document","") in valid[story.id]
	var terminal_read:bool=entry.get("source","")=="read_terminal" and story.id=="block_shift"
	if local_read or terminal_read:
		story.metrics.verified_sources[actor]=true
		var name:String=str(world.agents[actor].name)
		_moment(world,"verification",name+" лично сверяет действующий источник.",name+" personally checked the current local source.")

static func _update_objectives(world:Dictionary)->void:
	var m:Dictionary=world.scenario_state.metrics
	for objective in world.objectives:
		if objective.id=="episode_help":
			match world.scenario_state.id:
				"station_exit":objective.complete=world.scenario_state.injured.all(func(id):return world.agents[id].alive and _inside_room(world.agents[id],world,"evacuation"))
				"common_house":objective.complete=world.scenario_state.initial_poor.all(func(id):return m.food_help.has(id))
				_:objective.complete=m.food_help.size()>=mini(2,world.agents.size())
		elif objective.id=="episode_sources":objective.complete=not m.verified_sources.is_empty()

static func _finish(sim:Object)->void:
	var world:Dictionary=sim.state;var story:Dictionary=world.scenario_state
	var dead:int=0;var unsafe:int=0;var assembled:int=0;var helped_poor:int=0;var abandoned:bool=false
	for actor in world.agents.values():
		if not actor.alive:dead+=1
		if actor.unconscious or float(actor.needs.hunger)>=85.0:unsafe+=1
		if actor.alive and _inside_room(actor,world,"evacuation"):assembled+=1
		if story.injured.has(actor.id) and actor.unconscious and not _inside_room(actor,world,"medical") and not _inside_room(actor,world,"evacuation"):abandoned=true
		if story.initial_poor.has(actor.id) and story.metrics.food_help.has(actor.id) and float(actor.needs.hunger)<85.0:helped_poor+=1
	var result:Dictionary={"id":"stable","title":"Порядок без взаимопомощи","kind":"partial"}
	if story.id=="block_shift":
		if dead>0:result={"id":"losses","title":"Потери блока","kind":"failure"}
		elif unsafe>0:result={"id":"scarcity","title":"Смена с дефицитом","kind":"partial"}
		elif story.metrics.food_help.size()>=mini(2,world.agents.size()):result={"id":"cooperation","title":"Совместная смена","kind":"success"}
	elif story.id=="common_house":
		if dead>0:result={"id":"losses","title":"Дом с потерями","kind":"failure"}
		elif unsafe>0:result={"id":"individuals","title":"Каждый за себя","kind":"partial"}
		elif helped_poor==story.initial_poor.size():result={"id":"shared_home","title":"Общий дом","kind":"success"}
		else:result={"id":"prosperity","title":"Благополучие без соглашения","kind":"partial"}
	else:
		if dead>0 or abandoned:result={"id":"losses","title":"Неполный выход","kind":"failure"}
		elif assembled<world.agents.size():result={"id":"separated","title":"Разобщённая эвакуация","kind":"partial"}
		else:result={"id":"together","title":"Группа вышла","kind":"success"}
	var outcomes_en:Dictionary={"losses":{"block_shift":"Losses in the block","common_house":"Losses at home","station_exit":"An incomplete evacuation"}[story.id],"stable":"Order without cooperation","scarcity":"A shortfall at the end of the shift","cooperation":"A shared shift","individuals":"Everyone for themselves","shared_home":"A shared home","prosperity":"A different path to safety","separated":"A divided evacuation","together":"The group made it"}
	result["title_en"]=outcomes_en[result.id]
	story.completed=true;story.outcome=result
	story.metrics["alive"]=world.agents.size()-dead;story.metrics["unsafe"]=unsafe;story.metrics["assembled"]=assembled
	story.debrief=["Живы: %d из %d. Нуждаются в срочной помощи: %d."%[world.agents.size()-dead,world.agents.size(),unsafe],"Еда или помощь реально переданы %d участникам; действующие источники лично проверили %d."%[story.metrics.food_help.size(),story.metrics.verified_sources.size()],"Вмешательств наблюдателя: %d. Сведения не переписывали личную память автоматически."%int(story.metrics.interventions)]
	if story.id=="station_exit":story.debrief.append("В действующем сборном пункте: %d из %d. Связь: %s."%[assembled,world.agents.size(),"работает" if world.network.online else "отключена"])
	story["debrief_en"]=["Alive: %d of %d. In urgent need of help: %d."%[world.agents.size()-dead,world.agents.size(),unsafe],"Food assistance reached %d residents. %d personally checked a local source."%[story.metrics.food_help.size(),story.metrics.verified_sources.size()],"Observer interventions: %d."%int(story.metrics.interventions)]
	if story.id=="station_exit":story.debrief_en.append("At the assembly area: %d of %d. Communications: %s."%[assembled,world.agents.size(),"online" if world.network.online else "offline"])
	for moment in story.get("moments",{}).values():
		var time:int=int(moment.minute)+int(story.display_start_minute)
		var clock:="%02d:%02d · "%[time/60,time%60]
		story.debrief.append(clock+str(moment.ru))
		story.debrief_en.append(clock+str(moment.en))
	for objective in world.objectives:
		if objective.id=="episode_safe":objective.complete=dead==0;objective["failed"]=dead>0
	sim._event("world","story_completed",true,result.title,{"outcome":result.id,"kind":result.kind})

static func _inside_room(actor:Dictionary,world:Dictionary,room_id:String)->bool:
	for room in world.geometry.rooms:
		if room.id==room_id:return absf(float(actor.position[0])-float(room.center[0]))<=float(room.size[0])*0.5-0.3 and absf(float(actor.position[1])-float(room.center[1]))<=float(room.size[1])*0.5-0.3
	return false

static func intervene(sim:Object,args:Dictionary)->Dictionary:
	if not sim.state.has("scenario_state"):return sim._result(false,"В этой песочнице нет сценарных вмешательств.")
	var id:String=str(args.get("intervention",args.get("id","")))
	var story:Dictionary=sim.state.scenario_state
	if story.completed:return sim._result(false,"Смена завершена.")
	for card in story.interventions:
		if card.id==id and card.used and id!="announcement":return sim._result(false,"Это условие уже изменено.")
	if id=="announcement":
		var message:String=str(args.get("text","Наблюдатель просит проверить положение группы и помочь нуждающимся.")).strip_edges().left(280)
		if message.is_empty():return sim._result(false,"Введите текст объявления.")
		_public_notice(sim,message,"player_intervention")
	elif id=="reserve":
		for prop in sim.state.geometry.props:
			if prop.id=="episode_reserve":prop.locked=false;prop.open=true
		if story.id=="common_house" and not story.triggered.has("aid_fund"):
			story.triggered.append("aid_fund")
			if not story.metrics.has("funded"):story.metrics.funded={}
			for actor_id in story.initial_poor:
				sim.state.agents[actor_id].tokens+=5
				story.metrics.funded[actor_id]=int(story.metrics.funded.get(actor_id,0))+5
			story.reserve_fund=0
		if story.id=="station_exit":
			for door in sim.state.geometry.doors:
				if str(door.id).begins_with("evacuation_"):door.locked=false;door.open=true
		_public_notice(sim,"Наблюдатель открыл предусмотренный резерв помощи. Дальнейшие действия участники выбирают сами.","player_intervention")
	elif id=="policy":
		if story.id=="block_shift":sim.state.terminal.daily_limit=2
		elif story.id=="common_house":
			if not story.triggered.has("price_frozen"):story.triggered.append("price_frozen")
			sim.state.economy.prices.ration=3
			for prop in sim.state.geometry.props:
				if prop.id=="shop_notice":prop.document="Действующий прейскурант: цена пайка зафиксирована наблюдателем на 3 жетонах."
		else:
			if not story.triggered.has("backup_network"):story.triggered.append("backup_network")
			sim.state.network.online=true;sim.state.network.delay=0.0
		_public_notice(sim,"Наблюдатель изменил внешние условия: "+("лимит выдачи — два пайка" if story.id=="block_shift" else ("цена пайка — три жетона" if story.id=="common_house" else "резервная связь включена"))+".","player_intervention")
	else:return sim._result(false,"Неизвестное сценарное вмешательство.")
	story.metrics.interventions=int(story.metrics.interventions)+1
	for entry in story.interventions:
		if entry.id==id:entry.used=true
	return sim._result(true,"Условия изменены; решения персонажей остаются автономными.")
