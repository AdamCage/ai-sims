extends RefCounted
## Composition of authoritative social services; no module talks to models.
const Economy=preload("res://scripts/game/economy_rules.gd")
const Artifacts=preload("res://scripts/game/artifact_rules.gd")
const Network=preload("res://scripts/game/network_rules.gd")

static func execute(world:Object,id:String,action:Dictionary,resolved:Dictionary)->Dictionary:
	if action.type in ["request_ration","join_queue","return_device","transfer_tokens","buy","sell","offer","accept_offer","fulfil_promise"]:return Economy.execute(world,id,action,resolved)
	if action.type in ["write_diary","read_diary","take_photo","view_photo","show_photo","copy_photo","destroy"]:return Artifacts.execute(world,id,action,resolved)
	return Network.execute(world,id,action)

static func terminal_request(world:Object,id:String,kind:String)->Dictionary:
	return Economy.terminal_request(world,id,kind)

static func advance(world:Object,minutes:float)->void:
	Economy.advance(world,minutes)
	Network.advance(world,minutes)
	Artifacts.advance(world,minutes)

static func screen(world:Object,id:String)->Dictionary:
	return Network.screen(world,id)
