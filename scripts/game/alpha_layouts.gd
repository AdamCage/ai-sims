extends RefCounted
## Walkable authored neighbourhoods. Geometry is shared by rendering and rules.

static func build(map_id:String,w:float,d:float)->Dictionary:
	var g:Dictionary={"bounds":[-w,w,-d,d],"walls":[],"doors":[],"props":[],"rooms":[],"zones":{},"districts":[],"landmarks":[],"palette":{"closed_block":"teal","residence":"warm","research_station":"blue"}.get(map_id,"teal")}
	for edge in [[[-w,0.0],[0.24,d*2.0]],[[w,0.0],[0.24,d*2.0]],[[0.0,-d],[w*2.0,0.24]],[[0.0,d],[w*2.0,0.24]]]:_wall(g,edge[0],edge[1])
	var places:Array=[]
	if map_id=="closed_block":
		_district(g,"homes","Жилое крыло",[-16.0,-12.0],[30.0,22.0])
		_district(g,"commons","Общий двор",[0.0,0.0],[32.0,20.0])
		_district(g,"services","Снабжение и связь",[16.0,12.0],[30.0,22.0])
		places=[
			["bedroom_a","Северная спальня","homes",[-24.0,-16.0],[13.0,10.0],"bedroom","south"],
			["dining","Кухня и столовая","homes",[-8.0,-16.0],[13.0,10.0],"kitchen","south"],
			["medical","Медпункт","homes",[8.0,-16.0],[13.0,10.0],"medical","south"],
			["arrival","Погрузочный шлюз","services",[24.0,-16.0],[13.0,10.0],"arrival","south"],
			["supply","Выдача пайков","services",[24.0,16.0],[13.0,10.0],"supply","north"],
			["reserve","Резерв блока","services",[8.0,16.0],[13.0,10.0],"reserve","north"],
			["comms","Комната связи","services",[-8.0,16.0],[13.0,10.0],"comms","north"],
			["bedroom_b","Южная спальня","homes",[-24.0,16.0],[13.0,10.0],"bedroom","north"],
			["common","Общий зал","commons",[-25.0,-5.0],[11.0,8.0],"common","east"],
			["workshop","Мастерская","commons",[-25.0,5.0],[11.0,8.0],"workshop","east"],
			["shop","Обменный пункт","commons",[25.0,-5.0],[11.0,8.0],"shop","west"],
			["lab","Архив блока","commons",[25.0,5.0],[11.0,8.0],"lab","west"]]
		g.zones.spawn=[0.0,0.0]
	elif map_id=="residence":
		_district(g,"homes","Жилые дворы",[-32.0,0.0],[26.0,66.0])
		_district(g,"civic","Общественный проспект",[0.0,0.0],[26.0,66.0])
		_district(g,"market","Торговая улица",[32.0,0.0],[26.0,66.0])
		var ids:Array=["bedroom_a","bedroom_b","arrival","reserve","dining","common","medical","comms","shop","supply","workshop","lab"]
		var labels:Array=["Дом у часов","Дом с садом","Почтовая","Общая кладовая","Общественная кухня","Зал собраний","Аптечный пункт","Доска связи","Продуктовая лавка","Пункт оборудования","Мастерская","Читальный зал"]
		var functions:Array=["bedroom","bedroom","arrival","reserve","kitchen","common","medical","comms","shop","supply","workshop","lab"]
		for column in 3:
			for row in 4:
				var index:int=column*4+row
				places.append([ids[index],labels[index],["homes","civic","market"][column],[-32.0+column*32.0,-25.0+row*16.5],[22.0,12.0],functions[index],"east" if column<2 else "west"])
		g.zones.spawn=[-16.0,0.0]
	else:
		_district(g,"habitat","Жилой модуль",[-42.0,0.0],[34.0,72.0])
		_district(g,"science","Исследовательский модуль",[0.0,0.0],[34.0,72.0])
		_district(g,"operations","Связь и эвакуация",[42.0,0.0],[34.0,72.0])
		var ids:Array=["bedroom_a","dining","bedroom_b","medical","lab","workshop","reserve","common","comms","supply","arrival","evacuation"]
		var labels:Array=["Спальные каюты","Камбуз","Комната отдыха","Медицинский блок","Лаборатория","Мастерская","Архив наблюдений","Наблюдательная","Узел связи","Склад экспедиции","Северный шлюз","Южный сборный пункт"]
		var functions:Array=["bedroom","kitchen","bedroom","medical","lab","workshop","reserve","common","comms","supply","arrival","evacuation"]
		for module in 3:
			for index in 4:
				var position:Array=[-42.0+module*42.0+(-8.0 if index%2==0 else 8.0),-21.0 if index<2 else 21.0]
				var number:int=module*4+index
				places.append([ids[number],labels[number],["habitat","science","operations"][module],position,[14.0,22.0],functions[number],"south" if index<2 else "north"])
		g.zones.spawn=[-42.0,0.0]
	for index in places.size():
		var p:Array=places[index]
		_building(g,str(p[0]),str(p[1]),str(p[2]),p[3],p[4],str(p[5]),str(p[6]),index<(0 if map_id=="closed_block" else (4 if map_id=="residence" else 8)))
		g.zones[str(p[0])]=p[3].duplicate()
	# Five persistent, named orientation points; these are visible places, not AI knowledge.
	for key in ["arrival","supply","medical","comms","common"]:
		var room:Dictionary=g.rooms.filter(func(r):return r.id==key)[0]
		g.landmarks.append({"id":"landmark_"+key,"label":room.label,"kind":room.function,"center":room.center.duplicate()})
	return g

static func _district(g:Dictionary,id:String,label:String,center:Array,size:Array)->void:
	g.districts.append({"id":id,"label":label,"name":label,"center":center,"size":size})

static func _building(g:Dictionary,id:String,label:String,district:String,center:Array,size:Array,function:String,front:String,extra_door:bool)->void:
	g.rooms.append({"id":id,"name":label,"label":label,"district":district,"function":function,"center":center.duplicate(),"size":size.duplicate()})
	var cx:float=center[0];var cz:float=center[1];var hx:float=size[0]*0.5;var hz:float=size[1]*0.5
	for side in ["north","south","west","east"]:
		var horizontal:bool=side in ["north","south"]
		var point:Array=[cx,cz+(-hz if side=="north" else hz)] if horizontal else [cx+(-hx if side=="west" else hx),cz]
		var length:float=size[0] if horizontal else size[1]
		var opposite:String={"north":"south","south":"north","east":"west","west":"east"}[front]
		if side==front or side==opposite or (extra_door and side==("west" if front in ["north","south"] else "north")):
			var segment:float=(length-2.4)*0.5
			for sign_value in [-1.0,1.0]:
				var offset:float=sign_value*(1.2+segment*0.5)
				_wall(g,[point[0]+offset if horizontal else point[0],point[1] if horizontal else point[1]+offset],[segment,0.20] if horizontal else [0.20,segment])
			g.doors.append({"id":id+"_"+side,"center":point,"size":[2.4,0.20] if horizontal else [0.20,2.4],"height":2.8,"open":true,"locked":false})
		else:_wall(g,point,[length,0.20] if horizontal else [0.20,length])
	_furnish(g,id,center,size,function)

static func _furnish(g:Dictionary,id:String,p:Array,size:Array,function:String)->void:
	var x:float=p[0];var z:float=p[1];var left:float=x-float(size[0])*0.5+1.3;var back:float=z-float(size[1])*0.5+1.5
	var right:float=x+float(size[0])*0.5-1.1
	var front:float=z+float(size[1])*0.5-1.15
	# Furniture is offset from door axes, keeping room centres and through routes clear.
	_prop(g,id+"_light","lamp",[left,back],[0.35,0.35],2.0)
	match function:
		"bedroom":
			for index in 3:_prop(g,id+"_bed_%d"%index,"bed",[left+index*2.6,back+1.7],[1.25,2.25],0.65)
			_prop(g,id+"_wardrobe","wardrobe",[x+size[0]*0.5-0.8,z+2.2],[0.8,2.2],1.9)
		"supply":
			_prop(g,"supply_terminal","terminal",[x+size[0]*0.5-1.0,z-2.5],[0.8,0.8],1.5)
			_prop(g,id+"_shelf","shelf",[left+2.0,back],[3.6,0.8],1.9)
		"shop":_prop(g,"shop_counter","shop",[left+2.0,z+2.0],[3.6,1.0],1.0)
		"comms":
			_prop(g,"network_console","console",[left+1.0,z-2.0],[1.5,0.8],1.4)
			_prop(g,id+"_desk","table",[x+2.0,back],[2.4,1.0],0.8)
		"medical":
			for index in 2:_prop(g,id+"_bed_%d"%index,"medicalbed",[left+index*3.0,back+1.8],[1.25,2.3],0.7)
			_prop(g,id+"_cabinet","wardrobe",[x+size[0]*0.5-0.8,z+2.0],[0.8,1.5],1.9)
		"kitchen":
			_prop(g,id+"_counter","counter",[left+2.0,back],[3.2,0.8],0.95)
			_prop(g,id+"_fridge","fridge",[x+size[0]*0.5-1.0,back],[0.9,0.9],1.9)
			_prop(g,id+"_table","table",[x-2.2,z+2.0],[2.4,1.4],0.8)
		"reserve":_prop(g,"episode_reserve","wardrobe",[left+1.0,z-2.0],[1.2,1.0],1.8)
		"lab","workshop":
			_prop(g,id+"_bench","labdesk",[left+2.0,back],[3.0,1.1],0.9)
			_prop(g,id+"_cabinet","shelf",[x+size[0]*0.5-0.8,z+2.5],[0.8,2.5],1.9)
		_:
			_prop(g,id+"_sofa","sofa",[left+1.0,z+2.0],[2.6,1.0],0.9)
			_prop(g,id+"_table","table",[x+2.0,back],[2.0,1.0],0.7)
	_prop(g,id+"_notice","noticeboard",[x+size[0]*0.5-1.0,z+size[1]*0.5-1.0],[0.9,0.35],1.8)
	g.props[-1]["label"]=g.rooms[-1].label
	g.props[-1]["document"]="Вы находитесь: "+str(g.rooms[-1].label)+". Осмотрите доступные предметы и людей; проходы связывают районы."
	# Furniture grouped by use. The centre line between each pair of doors is a passage.
	match function:
		"common", "arrival", "evacuation":
			var bookcase_label: String = {"teal":"Полка смены","warm":"Библиотека соседей","blue":"Архив экспедиции"}[g.palette]
			_dress(g,id+"_reading_shelf","shelf",bookcase_label,[left+1.65,back],[2.1,0.72],1.8)
			for index in 2:_dress(g,id+"_reading_seat_%d"%index,"chair","Место у стола",[x+1.45+index*1.1,back+1.25],[0.65,0.65],0.95)
			if g.palette=="warm":
				_dress(g,id+"_fern","plant","Папоротник",[right,back],[0.7,0.7],1.45)
				_dress(g,id+"_window_seat","sofa","Диван у окна",[x+3.1,front],[2.6,1.05],0.95)
			elif g.palette=="blue":
				_dress(g,id+"_equipment","crate","Снаряжение экспедиции",[right,back+1.1],[1.1,1.0],0.85)
			else:_dress(g,id+"_plant","plant","Комнатное растение",[right,back],[0.65,0.65],1.5)
		"kitchen":
			_dress(g,id+"_sink","sink","Кухонная раковина",[right,back+1.4],[0.78,0.68],0.95)
			for index in 2:_dress(g,id+"_chair_%d"%index,"chair","Обеденный стул",[x-2.85+index*1.3,z+3.45],[0.65,0.65],0.95)
			_dress(g,id+"_pantry","shelf","Полка для посуды",[x+2.1,front],[2.2,0.72],1.7)
		"supply","reserve":
			_dress(g,id+"_shipment","crate","Контейнер поставки",[left+1.2,front],[1.2,1.0],0.85)
			_dress(g,id+"_shipment_small","crate","Транспортный ящик",[left+2.65,front],[0.9,1.0],0.75)
			_dress(g,id+"_locker","wardrobe","Служебный шкаф",[right,front-1.9],[0.8,1.35],1.9)
		"lab","workshop":
			_dress(g,id+"_stool","chair","Рабочее место",[left+1.6,back+1.35],[0.65,0.65],0.95)
			_dress(g,id+"_tool_chest","crate","Ящик инструментов",[left+1.1,front],[1.15,0.9],0.8)
			_dress(g,id+"_bench_right","table","Стол образцов" if g.palette=="blue" else "Стол мастера",[x+2.6,back],[2.1,0.9],0.85)
		"medical":
			_dress(g,id+"_sink","sink","Умывальник",[right,back],[0.78,0.68],0.95)
			_dress(g,id+"_supply","shelf","Медицинские принадлежности",[left+1.5,front],[2.2,0.72],1.65)
		"bedroom":
			_dress(g,id+"_reading_desk","table","Письменный стол",[left+1.6,front],[2.2,0.9],0.8)
			_dress(g,id+"_chair","chair","Стул у письменного стола",[left+1.6,front-1.25],[0.65,0.65],0.95)
		"comms","shop":
			_dress(g,id+"_records","shelf","Журнал связи" if function=="comms" else "Товарная полка",[right,back],[2.0,0.7],1.7)
			_dress(g,id+"_seat","chair","Рабочее кресло",[x+2.0,back+1.3],[0.65,0.65],0.95)
			_dress(g,id+"_side_stock","crate","Ящик поставок",[left+0.4,front],[1.05,0.85],0.8)

static func _dress(g:Dictionary,id:String,kind:String,label:String,center:Array,size:Array,height:float)->void:
	var bounds:=Rect2(Vector2(center[0],center[1])-Vector2(size[0],size[1])*0.5,Vector2(size[0],size[1]))
	for prop in g.props:
		var extent:=Vector2(prop.size[0],prop.size[1])
		if bounds.grow(0.1).intersects(Rect2(Vector2(prop.center[0],prop.center[1])-extent*0.5,extent)):return
	_prop(g,id,kind,center,size,height)
	g.props[-1]["label"]=label

static func _wall(g:Dictionary,center:Array,size:Array)->void:
	g.walls.append({"id":"wall_%d"%g.walls.size(),"center":center,"size":size,"height":2.8})

static func _prop(g:Dictionary,id:String,kind:String,center:Array,size:Array,height:float)->void:
	g.props.append({"id":id,"kind":kind,"center":center,"size":size,"height":height,"angle":0.0,"blocking":true})
