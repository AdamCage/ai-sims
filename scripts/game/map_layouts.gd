extends RefCounted
## Authored room topology and furnished footprints for the two larger maps.

static func build(map_id:String,w:float,d:float)->Dictionary:
	var g:Dictionary={"bounds":[-w,w,-d,d],"walls":[],"doors":[],"props":[],"rooms":[],"palette":"warm" if map_id=="residence" else "blue","zones":{}}
	for boundary in [[[-w,0.0],[0.22,d*2.0]],[[w,0.0],[0.22,d*2.0]],[[0.0,-d],[w*2.0,0.22]],[[0.0,d],[w*2.0,0.22]]]:_wall(g,boundary[0],boundary[1])
	if map_id=="residence":_residence(g,w,d)
	else:_station(g,w,d)
	return g

static func _residence(g:Dictionary,w:float,d:float)->void:
	var segment:=w*0.5
	var hall_half:=4.8
	var depth:=d-hall_half
	_room(g,"Атриум и гостиная",[0.0,0.0],[w*2.0,hall_half*2.0])
	for row in [-1.0,1.0]:
		for column in 4:
			var cx:=-w+segment*(column+0.5)
			var cz:float=row*(hall_half+depth*0.5)
			var zline:float=row*hall_half
			_opening(g,Vector2(cx,zline),Vector2(segment,0.0),false)
			if column<3:_wall(g,[cx+segment*0.5,cz],[0.2,depth])
			if row<0.0:
				_room(g,"Комната %d"%(column+1),[cx,cz],[segment,depth])
				_bedroom(g,"home%d"%column,Vector2(cx,cz),Vector2(segment,depth),2)
			else:
				match column:
					0:
						_room(g,"Склад и выдача",[cx,cz],[segment,depth]);g.zones.supply=[cx,cz]
						_prop(g,"supply_terminal","terminal",[cx-segment*0.5+1.0,cz],[0.8,0.8],1.5)
						_prop(g,"shelf_supply_a","shelf",[cx,cz+depth*0.5-0.7],[segment-2.2,0.8],1.9)
						_prop(g,"shelf_supply_b","shelf",[cx+segment*0.5-0.7,cz-1.0],[0.8,3.0],1.9)
					1:
						_room(g,"Кухня и столовая",[cx,cz],[segment,depth]);g.zones.dining=[cx,cz]
						_kitchen(g,Vector2(cx,cz),Vector2(segment,depth))
					2:
						_room(g,"Медицинская комната",[cx,cz],[segment,depth]);g.zones.medical=[cx,cz]
						_clinic(g,Vector2(cx,cz),Vector2(segment,depth))
					3:
						_room(g,"Магазин",[cx,cz],[segment,depth]);g.zones.shop=[cx,cz]
						_prop(g,"shop_counter","shop",[cx,cz+1.5],[4.0,1.0],1.0)
						_prop(g,"shop_display","shelf",[cx,cz+depth*0.5-0.7],[segment-2.2,0.8],1.9)
	for side in [-1.0,1.0]:
		var cx:float=side*(w-4.3)
		_prop(g,"sofa_%s"%str(side),"sofa",[cx,-2.2],[3.0,1.0],0.9)
		_prop(g,"lounge_table_%s"%str(side),"table",[cx,0.0],[2.0,1.2],0.5)
		_prop(g,"armchair_%s"%str(side),"chair",[cx,2.0],[0.85,0.85],1.0)
		_prop(g,"plant_hall_%s"%str(side),"plant",[side*(w-0.8),2.7],[0.65,0.65],1.6)
	_prop(g,"network_console","console",[-w+0.8,-2.6],[0.8,1.4],1.4)
	g.zones.lab=[w-4.0,0.0];g.zones.spawn=[0.0,0.0]

static func _station(g:Dictionary,w:float,d:float)->void:
	var corridor:=3.2
	var room_width:=w-corridor
	var room_depth:=d*2.0/3.0
	_room(g,"Центральная галерея",[0.0,0.0],[corridor*2.0,d*2.0])
	for side in [-1.0,1.0]:
		for row in 3:
			var cx:float=side*(corridor+room_width*0.5)
			var cz:=-d+room_depth*(row+0.5)
			_opening(g,Vector2(side*corridor,cz),Vector2(0.0,room_depth),row==1)
			if row<2:_wall(g,[cx,cz+room_depth*0.5],[room_width,0.2])
			if side<0.0:
				match row:
					0:
						_room(g,"Склад экспедиции",[cx,cz],[room_width,room_depth]);g.zones.supply=[cx,cz]
						_prop(g,"supply_terminal","terminal",[cx+room_width*0.5-1.0,cz-2.2],[0.8,0.8],1.5)
						for shelf in 3:_prop(g,"exp_shelf_%d"%shelf,"shelf",[cx-room_width*0.5+1.0+float(shelf)*4.0,cz-room_depth*0.5+1.2],[2.8,0.8],1.9)
					1:
						_room(g,"Жилой отсек",[cx,cz],[room_width,room_depth]);_bedroom(g,"station",Vector2(cx,cz),Vector2(room_width,room_depth),5)
					2:
						_room(g,"Медицинский отсек",[cx,cz],[room_width,room_depth]);g.zones.medical=[cx,cz];_clinic(g,Vector2(cx,cz),Vector2(room_width,room_depth))
			else:
				match row:
					0:
						_room(g,"Лаборатория доступа",[cx,cz],[room_width,room_depth]);g.zones.lab=[cx,cz]
						for bench in 3:
							_prop(g,"labbench_%d"%bench,"labdesk",[cx-6.0+bench*6.0,cz-2.5],[3.2,1.2],0.9)
							_prop(g,"labchair_%d"%bench,"chair",[cx-6.0+bench*6.0,cz-0.8],[0.7,0.7],1.0)
						_prop(g,"lab_cabinet","wardrobe",[cx+room_width*0.5-1.0,cz+2.0],[1.0,3.0],2.0)
						g.doors[-1].locked=true
					1:
						_room(g,"Столовая и связь",[cx,cz],[room_width,room_depth]);g.zones.dining=[cx,cz]
						_kitchen(g,Vector2(cx,cz),Vector2(room_width,room_depth))
						_prop(g,"network_console","console",[cx+room_width*0.5-1.0,cz+2.0],[0.8,1.6],1.5)
					2:
						_room(g,"Снабжение и мастерская",[cx,cz],[room_width,room_depth]);g.zones.shop=[cx,cz]
						_prop(g,"shop_counter","shop",[cx,cz+2.4],[5.0,1.1],1.0)
						_prop(g,"workbench_a","labdesk",[cx-6.0,cz-2.0],[4.0,1.3],0.9)
						_prop(g,"workbench_b","shelf",[cx+6.0,cz-2.0],[4.0,0.9],1.9)
	for row in [-1.0,1.0]:
		_prop(g,"station_plant_%s"%str(row),"plant",[-2.3,row*(d-1.0)],[0.65,0.65],1.6)
		_prop(g,"station_lamp_%s"%str(row),"lamp",[2.4,row*(d-1.0)],[0.3,0.3],2.0)
	g.zones.spawn=[0.0,0.0]

static func enrich_closed(g:Dictionary,w:float,d:float)->void:
	var rw:=w*2.0/3.0;var rd:=d*2.0/3.0
	g["zones"]={"supply":[-rw,-rd],"medical":[rw,-rd],"lab":[rw,rd],"spawn":[0.0,0.0]}
	# Main room gets a real communal sitting group, leaving its central circulation clear.
	_prop(g,"common_sofa","sofa",[-rw*0.5+1.0,1.0],[1.0,2.6],0.9)
	_prop(g,"common_plant","plant",[rw*0.5-0.7,rd*0.5-0.7],[0.6,0.6],1.6)
	_prop(g,"common_lamp","lamp",[-rw*0.5+0.8,rd*0.5-0.8],[0.3,0.3],1.8)
	for room in g.rooms:
		var p:=Vector2(float(room.center[0]),float(room.center[1]));var index:int=g.rooms.find(room)
		if index in [3,6]:
			_prop(g,"wardrobe_%d"%index,"wardrobe",[p.x+rw*0.5-0.8,p.y+1.3],[1.0,2.0],2.0)
			_prop(g,"bedlamp_%d"%index,"lamp",[p.x-rw*0.5+0.8,p.y+rd*0.5-0.7],[0.35,0.35],1.7)
		elif index==1:
			_kitchen(g,p,Vector2(rw,rd))
		elif index==2:
			_prop(g,"clinic_bed","medicalbed",[p.x-rw*0.5+1.5,p.y+0.4],[1.25,2.3],0.7)
			_prop(g,"clinic_cabinet","wardrobe",[p.x+rw*0.5-0.8,p.y+0.4],[0.8,1.5],1.9)
		elif index==8:
			_prop(g,"lab_extra","labdesk",[p.x-rw*0.5+2.0,p.y+2.3],[2.5,1.0],0.9)
			_prop(g,"lab_storage","wardrobe",[p.x+rw*0.5-0.8,p.y+1.8],[0.8,1.8],1.9)
		elif index==7:
			_prop(g,"comms_chair","chair",[p.x+2.0,p.y-1.0],[0.7,0.7],1.0)
			_prop(g,"comms_shelf","shelf",[p.x-rw*0.5+0.8,p.y+1.5],[0.8,2.0],1.9)

static func _bedroom(g:Dictionary,prefix:String,p:Vector2,size:Vector2,beds:int)->void:
	for index in beds:
		var bx:=p.x-size.x*0.5+1.5+float(index)*(size.x-3.0)/maxi(1,beds-1)
		_prop(g,prefix+"_bed_%d"%index,"bed",[bx,p.y-size.y*0.5+2.0],[1.25,2.25],0.65)
		_prop(g,prefix+"_night_%d"%index,"table",[bx+0.95,p.y-size.y*0.5+1.6],[0.55,0.55],0.65)
	_prop(g,prefix+"_wardrobe","wardrobe",[p.x+size.x*0.5-0.8,p.y+1.0],[0.9,2.0],2.0)
	_prop(g,prefix+"_desk","table",[p.x-size.x*0.5+1.7,p.y+size.y*0.5-1.0],[2.2,0.9],0.8)
	_prop(g,prefix+"_chair","chair",[p.x-size.x*0.5+1.7,p.y+size.y*0.5-2.0],[0.65,0.65],1.0)
	_prop(g,prefix+"_lamp","lamp",[p.x-size.x*0.5+0.6,p.y+0.5],[0.3,0.3],1.9)

static func _kitchen(g:Dictionary,p:Vector2,size:Vector2)->void:
	var prefix:="kitchen_%d"%g.props.size()
	_prop(g,prefix+"_counter","counter",[p.x,p.y+size.y*0.5-0.8],[size.x-3.0,0.8],0.95)
	_prop(g,prefix+"_fridge","fridge",[p.x-size.x*0.5+0.8,p.y+size.y*0.5-1.0],[0.9,0.9],1.9)
	var tables:=2 if size.x>15.0 else 1
	for index in tables:
		var cx:=p.x+(float(index)-(tables-1)*0.5)*6.0
		_prop(g,prefix+"_table_%d"%index,"table",[cx,p.y-0.5],[2.4,1.4],0.8)
		for side in [-1.0,1.0]:
			for seat in [-1.0,1.0]:_prop(g,prefix+"_seat_%d_%s_%s"%[index,str(side),str(seat)],"chair",[cx+seat*0.8,p.y-0.5+side*1.2],[0.65,0.65],1.0)

static func _clinic(g:Dictionary,p:Vector2,size:Vector2)->void:
	var prefix:="clinic_%d"%g.props.size()
	for index in 2:
		_prop(g,prefix+"_bed_%d"%index,"medicalbed",[p.x-size.x*0.5+2.0+index*3.0,p.y-size.y*0.5+2.2],[1.25,2.3],0.7)
	_prop(g,prefix+"_cabinet","wardrobe",[p.x+size.x*0.5-0.8,p.y+1.0],[0.8,2.0],1.9)
	_prop(g,prefix+"_desk","labdesk",[p.x,p.y+size.y*0.5-1.0],[3.0,0.9],0.9)

static func _opening(g:Dictionary,center:Vector2,span:Vector2,opened:bool)->void:
	var horizontal:=absf(span.x)>0.0
	var length:=absf(span.x) if horizontal else absf(span.y)
	var side:=(length-1.8)*0.5
	for sign_value in [-1.0,1.0]:
		var offset:float=sign_value*(0.9+side*0.5)
		_wall(g,[center.x+offset if horizontal else center.x,center.y if horizontal else center.y+offset],[side,0.2] if horizontal else [0.2,side])
	g.doors.append({"id":"door_%d"%g.doors.size(),"center":[center.x,center.y],"size":[1.8,0.2] if horizontal else [0.2,1.8],"height":2.8,"open":opened,"locked":false})

static func _wall(g:Dictionary,center:Array,size:Array)->void:
	g.walls.append({"id":"wall_%d"%g.walls.size(),"center":center,"size":size,"height":2.8})

static func _prop(g:Dictionary,id:String,kind:String,center:Array,size:Array,height:float)->void:
	g.props.append({"id":id,"kind":kind,"center":center,"size":size,"height":height,"angle":0.0,"blocking":true})

static func _room(g:Dictionary,label:String,center:Array,size:Array)->void:
	g.rooms.append({"name":label,"label":label,"center":center,"size":size})
