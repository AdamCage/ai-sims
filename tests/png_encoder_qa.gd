extends SceneTree
## Lossless worker encoding and reset/free lifecycle; never accesses a provider.
const Encoder=preload("res://scripts/release_storage/png_encoder.gd")
var checks:=0
var failures:Array=[]
class Caller extends Node:
	const PNG=preload("res://scripts/release_storage/png_encoder.gd")
	var done:=false
	var encoded:PackedByteArray=PackedByteArray()
	func start(image:Image)->void:
		encoded=await PNG.encode(image,get_tree());done=true

func _initialize()->void:run.call_deferred()
func check(ok:bool,label:String)->void:
	checks+=1
	if not ok:failures.append(label);printerr("FAIL PNG: ",label)
	else:print("PASS PNG: ",label)

func fixture()->Image:
	var bytes:=PackedByteArray();bytes.resize(640*360*4)
	var state:int=12345
	for i in bytes.size():
		state=(state*1664525+1013904223)&0xffffffff
		bytes[i]=(state>>24)&255
	return Image.create_from_data(640,360,false,Image.FORMAT_RGBA8,bytes)

func run()->void:
	var image:Image=fixture()
	var expected:PackedByteArray=image.save_png_to_buffer()
	var before:=Time.get_ticks_usec()
	var encoded:PackedByteArray=await Encoder.encode(image,self)
	check(encoded==expected,"worker returns exact native lossless PNG bytes")
	var decoded:=Image.new()
	check(decoded.load_png_from_buffer(encoded)==OK and decoded.get_data()==image.get_data(),"decoded pixels preserve every RGBA byte")
	check(Encoder.pending_count()==0,"completed task is reaped")
	print("PNG QA encode wall_ms=",(Time.get_ticks_usec()-before)/1000.0)
	var receiver:=Caller.new();root.add_child(receiver);receiver.start(image)
	image.fill(Color.RED)
	while not receiver.done:await process_frame
	check(receiver.encoded==expected,"caller image mutation cannot alter the worker's private snapshot")
	receiver.free()
	var owner:=Caller.new();root.add_child(owner)
	owner.start(image)
	check(Encoder.pending_count()==1,"caller started one task before first await")
	owner.free()
	var deadline:=Time.get_ticks_msec()+10000
	var frames:=0
	while Encoder.pending_count()>0 and Time.get_ticks_msec()<deadline:
		await process_frame;frames+=1
	check(Encoder.pending_count()==0,"freeing caller still completes and reaps its task")
	check(frames>0,"main loop keeps processing while the worker encodes")
	check((await Encoder.encode(null,self)).is_empty(),"invalid image returns no manufactured pixels")
	check(Encoder.pending_count()==0,"invalid input starts no worker")
	print("PNG ENCODER QA: ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
