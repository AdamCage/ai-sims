extends RefCounted
const Repository=preload("res://scripts/release_storage/session_repository.gd")
const Credentials=preload("res://scripts/release_storage/credential_store.gd")
var failures:Array=[]
var checks:=0
func check(ok:bool,message:String)->void:
	checks+=1
	if not ok:failures.append("Storage: "+message)
func run()->Array:
	var repo=Repository.new()
	repo.save_root="user://qa_storage/saves"
	repo.session_root="user://qa_storage/sessions"
	var state:Dictionary={"version":2,"map_id":"fixture","minute":0.0,"event_cursor":0,"agents":{"a":{"position":[0.0,0.0],"inventory":[]}},"items":{},"events":[]}
	repo.begin(state)
	var initial:=state.duplicate(true)
	var expected:Array=[initial]
	for index in range(1,31):
		state.minute=float(index)*.25;state.agents.a.position=[float(index)*.1,0.0]
		var event:Dictionary={"seq":index-1,"message":"fixture"};state.events.append(event);state.event_cursor=index
		if index==3:state.items["food"]={"holder":"a"};state.agents.a.inventory.append("food")
		if index==5:state.items.erase("food");state.agents.a.inventory.clear()
		repo.record(state,[event]);expected.append(state.duplicate(true))
	for index in [0,1,3,5,19,20,30]:
		check(repo.reconstruct(index)==JSON.parse_string(JSON.stringify(expected[index])),"reconstruct every transition/checkpoint "+str(index))
	var returned:Dictionary=repo.reconstruct(3);returned.agents.a.inventory.clear()
	check(repo.reconstruct(3)==JSON.parse_string(JSON.stringify(expected[3])),"replay copies detached")
	check(repo.save_slot(3,{"marker":"first","world":state})==OK,"first atomic save")
	check(repo.save_slot(3,{"marker":"second","world":state})==OK,"replacement atomic save")
	check(repo.load_slot(3).data.marker=="second","latest save restores")
	var path:String=repo.save_root.path_join("slot_3.json")
	var file:=FileAccess.open(path,FileAccess.WRITE);file.store_string("truncated");file.close()
	var recovered:Dictionary=repo.load_slot(3)
	check(recovered.get("recovered_backup",false) and recovered.data.marker=="first","corrupt current file restores previous complete save")
	var creds=Credentials.new()
	if OS.get_name()=="Windows":check(creds.self_test(),"credential manager isolated pipe roundtrip")
	var journal_path:String=repo.session_path.path_join("transitions.jsonl")
	repo.flush()
	var journal_text:=FileAccess.get_file_as_string(journal_path)
	var lines:=journal_text.strip_edges().split("\n")
	# Reconstruct before the next checkpoint so every required transition matters.
	var skipped:Array[String]=[]
	for line in lines:
		var entry:Dictionary=JSON.parse_string(line)
		if int(entry.sequence)!=2:skipped.append(line)
	var corrupted:=FileAccess.open(journal_path,FileAccess.WRITE);corrupted.store_string("\n".join(skipped)+"\n");corrupted.close()
	check(repo.reconstruct(3).is_empty(),"missing journal transition rejects replay instead of returning partial state")
	corrupted=FileAccess.open(journal_path,FileAccess.WRITE);corrupted.store_string(lines[0]+"\n");corrupted.close()
	check(repo.reconstruct(3).is_empty(),"truncated journal rejects unavailable target")
	print("Release storage: ",checks," checks; ",failures.size()," failures")
	return failures
