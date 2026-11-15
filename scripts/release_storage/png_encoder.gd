extends RefCounted
## GPU readback belongs to the main thread. Only a private CPU Image enters
## this worker; it never accesses a viewport, texture, node or SceneTree.
## The static coroutine belongs to this script resource, so a scene reset or
## deletion of its calling Node does not abandon the native worker task.

class EncodeJob extends RefCounted:
	var image:Image
	var result:PackedByteArray=PackedByteArray()
	func run()->void:
		result=image.save_png_to_buffer()

static var _active_jobs:int=0

static func encode(image:Image,tree:SceneTree)->PackedByteArray:
	if image==null or image.is_empty() or tree==null:return PackedByteArray()
	var job:=EncodeJob.new()
	# The caller remains free to release/reuse its readback after this copy. The
	# worker's Resource is not shared with scene presentation or another worker.
	job.image=image.duplicate() as Image
	_active_jobs+=1
	var task:int=WorkerThreadPool.add_task(Callable(job,"run"),false,"Encode exact personal PNG")
	if task<0:
		_active_jobs-=1
		return PackedByteArray()
	while not WorkerThreadPool.is_task_completed(task):
		await tree.process_frame
	# Always reap the task. Completion is also the synchronization boundary before
	# the main thread reads the worker's buffer or releases its private Image.
	WorkerThreadPool.wait_for_task_completion(task)
	_active_jobs-=1
	return job.result

static func pending_count()->int:
	return _active_jobs
