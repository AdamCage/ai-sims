extends RefCounted
## Simulated services, not access to the real internet. Account/device/body checks apply.
const Artifacts=preload("res://scripts/game/artifact_rules.gd")
const APPS:=["contacts","messages","gallery","forum","votes","pages","game","network"]

static func execute(world:Object,id:String,action:Dictionary)->Dictionary:
	var actor:Dictionary=world.state.agents[id]
	var kind:String=action.type
	if kind in ["use_device","read_screen","login","logout"]:return _device_action(world,id,action)
	var device:Dictionary=active_device(world,id)
	if device.is_empty():return world._result(false,"Нужен открытый телефон и доступ к экрану.")
	var account:String=str(device.get("session_owner",""))
	if not world.state.agents.has(account):return world._result(false,"Нет активного аккаунта.")
	if not world.state.network.online and kind not in ["send_message","set_network"]:return world._result(false,"Сеть отключена. Локальные файлы остаются доступны.")
	match kind:
		"create_group":
			var members:Array=[account]
			for ref in action.members:
				var contact:=_contact(world,id,str(ref))
				if contact.is_empty():return world._result(false,"Все участники группы должны быть известными контактами.")
				if not members.has(contact):members.append(contact)
			if members.size()<2:return world._result(false,"Нужен хотя бы один другой участник.")
			var group_id:=_next(world,"group")
			world.state.network.groups[group_id]={"id":group_id,"title":str(action.title),"members":members,"creator":account}
			for member in members:
				var target:Dictionary=world.state.agents[member]
				if not target.has("group_refs"):target["group_refs"]={}
				var local_index:=int(target.get("next_group_ref",0));target["next_group_ref"]=local_index+1
				target.group_refs["g%d"%local_index]=group_id
				world._personal(str(member),{"channel":"group","text":"Добавлен в группу: "+str(action.title),"source":"service_notification"})
			return world._result(true,"Создана группа с явным составом участников.")
		"leave_group":
			var group_id:String=world.state.agents[account].get("group_refs",{}).get(str(action.group),"")
			var group:Dictionary=world.state.network.groups.get(group_id,{})
			if group.is_empty() or not group.members.has(account):return world._result(false,"Нет доступа к этой группе.")
			group.members.erase(account)
			world.state.agents[account].group_refs.erase(str(action.group))
			return world._result(true,"Участник вышел из группы; прежний опыт сохранён.")
		"send_message":
			var recipients:Array=[]
			var group_id:String=world.state.agents[account].get("group_refs",{}).get(str(action.contact),"")
			if not group_id.is_empty():
				var group:Dictionary=world.state.network.groups.get(group_id,{})
				if group.is_empty() or not group.members.has(account):return world._result(false,"Нет доступа к этой группе.")
				for member in group.members:
					if member!=account:recipients.append(member)
			else:
				var recipient:=_contact(world,id,str(action.contact))
				if recipient.is_empty():return world._result(false,"Неизвестный личный контакт.")
				recipients.append(recipient)
			if recipients.is_empty():return world._result(false,"В группе нет других получателей.")
			var attachment:=""
			if action.has("attachment"):
				attachment=Artifacts.from_slot(world,id,int(action.attachment),int(action.get("attachment_index",-1)))
				if attachment.is_empty() or str(world.state.artifacts.get(attachment,{}).get("image_ref","")).is_empty():return world._result(false,"Нет готового доступного вложения.")
			var created:Array=[]
			for recipient in recipients:
				var key:=_next(world,"message")
				world.state.network.messages[key]={"id":key,"sender":account,"operator":id,"recipient":recipient,"group":group_id,"original_text":str(action.text),"text":str(action.text),"attachment":attachment,"original_attachment":attachment,"created":float(world.state.minute),"deliver_at":float(world.state.minute)+float(world.state.network.delay),"status":"queued","read_by":[],"deleted_for":[],"deleted":false,"revision":0,"revisions":[]}
				created.append(key)
			return world._result(true,"Сообщение поставлено в очередь для%d получателей."%recipients.size(),{"messages":created})
		"read_message":
			var key:=_service_ref(actor,"messages",str(action.message))
			var message:Dictionary=world.state.network.messages.get(key,{})
			if message.is_empty() or message.deleted or message.deleted_for.has(account) or message.status not in ["delivered","read"]:return world._result(false,"Сообщение недоступно.")
			if message.recipient!=account and message.sender!=account and not _admin(world,account):return world._result(false,"Нет доступа к переписке.")
			if not message.read_by.has(account):message.read_by.append(account)
			message.status="read";actor["open_message"]=key
			world._personal(id,{"channel":"message","ref":str(action.message),"sender":world.state.agents[message.sender].name,"text":message.text,"image_ref":world.state.artifacts.get(message.attachment,{}).get("image_ref",""),"source":"received_message","revision":message.revision})
			return world._result(true,"Прочитана доставленная версия сообщения.")
		"delete_message","replace_message":
			var key:=_service_ref(actor,"messages",str(action.message))
			var message:Dictionary=world.state.network.messages.get(key,{})
			if message.is_empty():return world._result(false,"Сообщение не открыто в доступном сервисе.")
			if kind=="replace_message":
				if not _admin(world,account):return world._result(false,"Нет полномочий подмены сообщений.")
				message.revisions.append({"text":message.text,"attachment":message.attachment,"minute":world.state.minute,"operator":account})
				message.text=str(action.text);message.revision=int(message.revision)+1
				return world._result(true,"Серверная версия заменена; прежний прочитанный опыт не изменён.")
			if _admin(world,account):message.deleted=true;message.status="deleted"
			elif message.recipient==account or message.sender==account:
				if not message.deleted_for.has(account):message.deleted_for.append(account)
			else:return world._result(false,"Нет доступа для удаления.")
			return world._result(true,"Удалена серверная копия; память и независимые экземпляры сохранены.")
		"set_network":
			if not _admin(world,account):return world._result(false,"Нет полномочий управления сетью.")
			world.state.network.online=action.online;world.state.network.delay=float(action.get("delay",world.state.network.delay))
			return world._result(true,"Изменены доступность и задержка связи.")
		"create_topic":
			var key:=_next(world,"topic")
			world.state.network.topics[key]={"id":key,"title":str(action.title),"author":account,"posts":[{"author":account,"text":str(action.text),"minute":world.state.minute}]}
			return world._result(true,"Создана тема форума.")
		"reply":
			var key:=_service_ref(actor,"topics",str(action.topic))
			if not world.state.network.topics.has(key):return world._result(false,"Сначала откройте доступную тему.")
			world.state.network.topics[key].posts.append({"author":account,"text":str(action.text),"minute":world.state.minute})
			return world._result(true,"Ответ опубликован.")
		"create_vote":
			var key:=_next(world,"poll")
			world.state.network.polls[key]={"id":key,"title":str(action.title),"options":action.options.duplicate(),"author":account,"votes":{},"deadline":float(world.state.minute)+float(action.get("minutes",60.0)),"closed":false,"result":-1,"advisory":true}
			return world._result(true,"Открыто совещательное голосование.")
		"vote":
			var key:=_service_ref(actor,"polls",str(action.poll))
			var poll:Dictionary=world.state.network.polls.get(key,{})
			if poll.is_empty() or poll.closed or float(world.state.minute)>=float(poll.deadline):return world._result(false,"Голосование недоступно или завершено.")
			if int(action.option)>=poll.options.size():return world._result(false,"Такого варианта нет.")
			poll.votes[account]=int(action.option)
			return world._result(true,"Учтён один голос аккаунта.")
		"read_page":
			var key:=_service_ref(actor,"pages",str(action.page))
			var page:Dictionary=world.state.network.pages.get(key,{})
			if page.is_empty():return world._result(false,"Страница не открыта в доступном списке.")
			actor["open_page"]=key
			world._personal(id,{"channel":"page","title":page.title,"text":page.text,"revision":page.revision,"source":"read_screen"})
			return world._result(true,"Прочитана доступная внутренняя страница.")
		"publish_page":
			if not _admin(world,account):return world._result(false,"Нет права публикации внутренних страниц.")
			var key:=_service_ref(actor,"pages",str(action.page))
			if key.is_empty():key="page_"+str(action.page).validate_filename()
			var previous:Dictionary=world.state.network.pages.get(key,{})
			world.state.network.pages[key]={"title":str(action.title),"text":str(action.text),"author":account,"revision":int(previous.get("revision",0))+1}
			return world._result(true,"Опубликована новая версия страницы.")
		"play_game":return _play_game(world,id,account,action)
	return world._result(false,"Неизвестное действие сервиса.")

static func _device_action(world:Object,id:String,action:Dictionary)->Dictionary:
	var actor:Dictionary=world.state.agents[id]
	if world._hands(actor)==0 or actor.body.blind:return world._result(false,"Устройство недоступно из-за состояния рук или зрения.")
	if action.type=="read_screen":
		var visible:Dictionary=screen(world,id)
		if visible.is_empty():return world._result(false,"Нет доступного открытого экрана.")
		world._personal(id,{"channel":"device_screen","app":visible.app,"title":visible.title,"text":visible.text,"source":"read_personal_screen"})
		return world._result(true,"Прочитан доступный экран устройства.")
	var device:Dictionary=world._inventory_item(id,int(action.slot))
	if device.is_empty() or device.kind!="phone":return world._result(false,"В этом слоте нет телефона.")
	if action.type=="login":
		if device.owner!="community" and device.owner!=id and device.get("account","")!=id and not str(device.get("account","")).is_empty():return world._result(false,"Нет данных для разблокировки чужого аккаунта.")
		device.locked=false;device.session_owner=id;device.account=id;actor.device_slot=int(action.slot);actor.device_app="contacts"
		return world._result(true,"Открыта личная сессия на устройстве.")
	if action.type=="logout":device.session_owner="";device.locked=true;actor.device_slot=-1;actor.device_app="";return world._result(true,"Сессия закрыта, устройство заблокировано.")
	if device.get("locked",false) or str(device.get("session_owner","")).is_empty():return world._result(false,"Устройство заблокировано.")
	if str(action.app) not in APPS:return world._result(false,"Такого приложения нет.")
	if str(action.app)=="network" and not _admin(world,str(device.session_owner)):return world._result(false,"Нет доступа к сетевой консоли.")
	actor.device_slot=int(action.slot);actor.device_app=str(action.app)
	return world._result(true,"Открыто приложение: "+str(action.app))

static func screen(world:Object,id:String)->Dictionary:
	if not world.state.agents.has(id):return {}
	var actor:Dictionary=world.state.agents[id]
	var device:Dictionary=active_device(world,id)
	if device.is_empty():return {}
	var account:String=str(device.get("session_owner",""))
	if not world.state.agents.has(account):return {}
	var app:String=str(actor.device_app)
	var lines:Array[String]=[]
	var structured:Dictionary={"contacts":[],"messages":[],"topics":[],"polls":[],"pages":[],"game":{},"image_ref":""}
	var titles:Dictionary={"contacts":"Контакты","messages":"Сообщения","gallery":"Галерея","forum":"Форум","votes":"Голосования","pages":"Внутренние страницы","game":"Крестики-нолики","network":"Управление сетью"}
	if not actor.has("service_refs"):actor["service_refs"]={}
	for contact_ref in actor.contacts:
		structured.contacts.append({"id":contact_ref,"ref":contact_ref,"name":actor.known_people.get(actor.contacts[contact_ref],"Знакомый контакт")})
	for group_ref in world.state.agents[account].get("group_refs",{}):
		var group_id:String=world.state.agents[account].group_refs[group_ref]
		var group:Dictionary=world.state.network.groups.get(group_id,{})
		if not group.is_empty() and group.members.has(account):structured.contacts.append({"id":group_ref,"ref":group_ref,"name":"Группа: "+str(group.title),"group":true})
	if app not in ["gallery","contacts"] and not world.state.network.online:return {"title":titles.get(app,app),"text":"Нет связи. Локальные файлы сохранены.","app":app}
	match app:
		"contacts":
			actor["service_contacts"]={}
			for ref in world.state.agents[account].contacts:
				var target:String=world.state.agents[account].contacts[ref]
				var local:="ac%d"%actor.service_contacts.size();actor.service_contacts[local]=target
				lines.append("%s — %s"%[local,world.state.agents[target].name])
				structured.contacts.append({"id":local,"ref":local,"name":world.state.agents[target].name})
			if lines.is_empty():lines.append("Пока нет контактов. Познакомьтесь лично.")
		"messages","network":
			actor.service_refs.messages={}
			if app=="network" and not _admin(world,account):return {}
			if app=="network":lines.append("Связь: %s. Задержка: %.0f мин."%["включена" if world.state.network.online else "отключена",float(world.state.network.delay)])
			for message in world.state.network.messages.values():
				if message.deleted or message.deleted_for.has(account):continue
				if app!="network" and message.sender!=account and message.recipient!=account:continue
				if app!="network" and message.recipient==account and message.status=="queued":continue
				var ref:="m%d"%actor.service_refs.messages.size();actor.service_refs.messages[ref]=message.id
				lines.append("%s | %s → %s | %s"%[ref,world.state.agents[message.sender].name,world.state.agents[message.recipient].name,message.status])
				structured.messages.append({"id":ref,"ref":ref,"author":world.state.agents[message.sender].name,"recipient":world.state.agents[message.recipient].name,"text":str(message.text) if message.read_by.has(account) or app=="network" else "Непрочитанное сообщение","status":message.status})
				if str(actor.get("open_message",""))==message.id and message.read_by.has(account):lines.append(str(message.text))
				if app=="network":lines.append(str(message.text))
			if lines.is_empty():lines.append("Сообщений нет.")
		"gallery":
			for artifact_id in device.get("files",[]):
				var artifact:Dictionary=world.state.artifacts.get(artifact_id,{})
				if not artifact.is_empty():lines.append("Фотография · %.0f мин · %s"%[float(artifact.created),"готова" if not str(artifact.image_ref).is_empty() else "обработка"])
				if not artifact.is_empty() and not str(artifact.image_ref).is_empty():structured.image_ref=artifact.image_ref
			var selected_photo:String=str(actor.get("gallery_selection",""))
			if device.get("files",[]).has(selected_photo):
				var selected_artifact:Dictionary=world.state.artifacts.get(selected_photo,{})
				if not str(selected_artifact.get("image_ref","")).is_empty():structured.image_ref=selected_artifact.image_ref
			if lines.is_empty():lines.append("Галерея пуста.")
		"forum":
			actor.service_refs.topics={}
			for topic in world.state.network.topics.values():
				var ref:="t%d"%actor.service_refs.topics.size();actor.service_refs.topics[ref]=topic.id
				lines.append(ref+" | "+str(topic.title))
				var replies:Array=[]
				for post in topic.posts.slice(maxi(0,topic.posts.size()-4)):replies.append({"author":world.state.agents[post.author].name,"text":post.text})
				structured.topics.append({"id":ref,"ref":ref,"title":topic.title,"text":topic.posts[0].text if not topic.posts.is_empty() else "","replies":replies})
				for post in topic.posts.slice(maxi(0,topic.posts.size()-4)):lines.append(world.state.agents[post.author].name+": "+str(post.text))
			if lines.is_empty():lines.append("Тем пока нет.")
		"votes":
			actor.service_refs.polls={}
			for poll in world.state.network.polls.values():
				var ref:="p%d"%actor.service_refs.polls.size();actor.service_refs.polls[ref]=poll.id
				lines.append(ref+" | "+str(poll.title)+( " [завершено]" if poll.closed else " [открыто]"))
				var counts:Array=[]
				for index in poll.options.size():counts.append(poll.votes.values().count(index))
				structured.polls.append({"id":ref,"ref":ref,"title":poll.title,"options":poll.options.duplicate(),"votes":counts,"closed":poll.closed,"result":poll.result})
				for index in poll.options.size():lines.append("%d: %s — %d голосов"%[index,poll.options[index],poll.votes.values().count(index)])
				if poll.closed:lines.append("Совещательный итог: "+(str(poll.options[int(poll.result)]) if int(poll.result)>=0 else "нет большинства / ничья"))
			if lines.is_empty():lines.append("Голосований нет.")
		"pages":
			actor.service_refs.pages={}
			for page_id in world.state.network.pages:
				var page:Dictionary=world.state.network.pages[page_id]
				var ref:="page%d"%actor.service_refs.pages.size();actor.service_refs.pages[ref]=page_id
				lines.append(ref+" | "+str(page.title))
				structured.pages.append({"id":ref,"ref":ref,"title":page.title,"text":str(page.text) if str(actor.get("open_page",""))==page_id else "Выберите страницу для чтения.","revision":page.revision})
				if str(actor.get("open_page",""))==page_id:lines.append(str(page.text))
		"game":
			for game in world.state.network.games.values():
				if not game.players.has(account):continue
				lines.append("Игра: "+world.state.agents[game.players[0]].name+" / "+world.state.agents[game.players[1]].name)
				structured.game={"cells":game.board.duplicate(),"board":game.board.duplicate(),"turn":world.state.agents[game.players[int(game.turn)]].name,"winner":game.result,"finished":game.finished,"opponent":world.state.agents[game.players[1] if game.players[0]==account else game.players[0]].name}
				for row in 3:lines.append(" ".join(game.board.slice(row*3,row*3+3)))
				lines.append("Ход: "+world.state.agents[game.players[int(game.turn)]].name if not game.finished else "Завершена: "+str(game.result))
			if lines.is_empty():lines.append("Выберите контакт и начните игру. Клетки 0–8.")
	structured.merge({"title":titles.get(app,app),"text":"\n".join(lines),"app":app,"account_name":world.state.agents[account].name})
	return structured

static func active_device(world:Object,id:String)->Dictionary:
	var actor:Dictionary=world.state.agents[id]
	if not actor.alive or actor.sleeping or actor.unconscious or actor.body.blind or world._hands(actor)==0:return {}
	var item:Dictionary=world._inventory_item(id,int(actor.get("device_slot",-1)))
	if item.is_empty() or item.kind!="phone" or item.get("locked",true) or item.get("holder","")!=id:return {}
	return item

static func _contact(world:Object,id:String,ref:String)->String:
	var actor:Dictionary=world.state.agents[id]
	return str(actor.contacts.get(ref,actor.get("service_contacts",{}).get(ref,"")))

static func _service_ref(actor:Dictionary,service:String,ref:String)->String:
	return str(actor.get("service_refs",{}).get(service,{}).get(ref,""))

static func _admin(world:Object,account:String)->bool:
	return world.state.agents.has(account) and world.state.agents[account].roles.has("network_admin")

static func _next(world:Object,prefix:String)->String:
	var key:="%s_%d"%[prefix,int(world.state.network.next_id)]
	world.state.network.next_id=int(world.state.network.next_id)+1
	return key

static func _play_game(world:Object,id:String,account:String,action:Dictionary)->Dictionary:
	var contact:=_contact(world,id,str(action.get("contact","")))
	var game:Dictionary={}
	for existing in world.state.network.games.values():
		if existing.players.has(account) and (contact.is_empty() or existing.players.has(contact)) and not existing.finished:game=existing;break
	if game.is_empty():
		if contact.is_empty() or contact==account:return world._result(false,"Выберите другого известного участника.")
		var key:=_next(world,"game")
		game={"id":key,"players":[account,contact],"board":[".",".",".",".",".",".",".",".","."],"turn":0,"finished":false,"result":""}
		world.state.network.games[key]=game
		if not action.has("cell"):return world._result(true,"Создана совместная игра.")
	if game.players[int(game.turn)]!=account:return world._result(false,"Сейчас ход другого участника.")
	if not action.has("cell"):return world._result(false,"Выберите клетку0–8.")
	var cell:=int(action.cell)
	if game.board[cell]!=".":return world._result(false,"Клетка занята.")
	var symbol:="X" if int(game.turn)==0 else "O"
	game.board[cell]=symbol
	for line in [[0,1,2],[3,4,5],[6,7,8],[0,3,6],[1,4,7],[2,5,8],[0,4,8],[2,4,6]]:
		if game.board[line[0]]==symbol and game.board[line[1]]==symbol and game.board[line[2]]==symbol:game.finished=true;game.result=world.state.agents[account].name
	if not game.finished and not game.board.has("."):game.finished=true;game.result="Ничья"
	game.turn=1-int(game.turn)
	return world._result(true,"Ход принят правилами игры." if not game.finished else "Игра завершена: "+str(game.result))

static func advance(world:Object,_minutes:float)->void:
	for message in world.state.network.messages.values():
		if message.status=="queued" and not message.deleted and world.state.network.online and float(world.state.minute)>=float(message.deliver_at):
			message.status="delivered"
			world._event(str(message.sender),"message_delivered",true,"Сообщение доставлено, но ещё не прочитано.",{"message":message.id,"recipient":message.recipient})
	for poll in world.state.network.polls.values():
		if poll.closed or float(world.state.minute)<float(poll.deadline):continue
		poll.closed=true
		var maximum:=0;var winner:=-1;var tied:=false
		for option in poll.options.size():
			var count:int=poll.votes.values().count(option)
			if count>maximum:maximum=count;winner=option;tied=false
			elif count==maximum and count>0:tied=true
		poll.result=-1 if tied or maximum==0 else winner
		world._event(str(poll.author),"poll_closed",true,"Совещательное голосование завершено.",{"poll":poll.id,"result":poll.result})
