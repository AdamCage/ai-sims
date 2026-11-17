extends SceneTree
const Bridge=preload("res://scripts/release_storage/web_bridge.gd")
const Ledger=preload("res://scripts/release_ai/usage_ledger.gd")
const Repository=preload("res://scripts/release_storage/session_repository.gd")
const Encoder=preload("res://scripts/release_storage/png_encoder.gd")
const Credentials=preload("res://scripts/release_storage/credential_store.gd")
const Transport=preload("res://scripts/release_ai/router_adapter.gd")
var failures:=0
var checks:=0
func check(value:bool,label:String)->void:
	checks+=1
	if not value:failures+=1;printerr("FAIL WEB ADAPTER: ",label)
func _initialize()->void:run.call_deferred()
func run()->void:
	check(not Bridge.is_web() and not Bridge.ready() and not Bridge.has_lease(),"native platform never pretends browser lease")
	check(Bridge.key().is_empty() and Bridge.status().is_empty(),"native bridge exposes no credentials")
	var ledger=Ledger.new();ledger.configure(1.0,"",1)
	check(ledger.reserve("web-fixture",0.25).ok,"explicit in-memory offline fixture reserves")
	check(ledger.abandon("web-fixture",true),"uncertain cancel recorded")
	check(is_equal_approx(float(ledger.status().unknown_rub),0.25),"unknown charge remains committed")
	var repository=Repository.new()
	repository.save_root="user://release_test_profile/alpha_web_saves"
	check(repository.save_slot(1,{"world":{"tick":9}})==OK,"native save adapter remains usable")
	check(repository.load_slot(1).get("data",{}).get("world",{}).get("tick")==9,"native save envelope roundtrip")
	check(not repository.import_browser_slots(),"native cannot import untrusted browser commands")
	var image=Image.create(3,2,false,Image.FORMAT_RGBA8);image.fill(Color(0.2,0.7,0.4,0.5))
	var png:PackedByteArray=await Encoder.encode(image,self)
	var decoded:=Image.new()
	check(decoded.load_png_from_buffer(png)==OK and decoded.get_data()==image.get_data(),"native PNG path preserves translucent pixels")
	print("ALPHA WEB ADAPTERS: ",checks," checks; ",failures," failures")
	quit(0 if failures==0 else 1)
