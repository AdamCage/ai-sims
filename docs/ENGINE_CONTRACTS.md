# First sprint contracts

Implementation contract, 15 November 2026. These reversible engineering defaults implement the goal objective; they do not resolve the design's remaining product questions.

## Shared data

All persisted state is JSON-compatible. Positions are `[x,z]` metres. `heading` is degrees, **0 faces -Z; +90 faces -X** (Godot positive Y rotation). Logical steps are one simulated minute. Rendering never mutates authoritative state.

`WorldState = {version:1, run_id:int, tick:int, elapsed_minutes:int, scenario:String, agents:Dictionary, items:Dictionary, geometry:{walls:Array,doors:Array}, events:Array}`.

Agent keys `ada`, `boris`, `cora`; values `{id,name,color:String,position:[x,z],heading:float,profile:{foundation:String,traits:Array},needs:{hunger:float,fatigue:float},body:{blind:bool,left_arm:String,right_arm:String,left_leg:String,right_leg:String},inventory:Array[String],last_action:Dictionary,last_result:Dictionary}`. Limb values `healthy`, `injured`, `broken`. Optional extra fields are private observer state. Item `{id,label,kind,position:[x,z],holder:String}`; empty holder means on ground. Never pass global IDs to a model.

`AgentAction` only one of `{type:"wait"}`, `{type:"look"}`, `{type:"move",forward:float,right:float}` (each -1..1, combined max length 1 metre), `{type:"turn",degrees:float}` (-180..180), `{type:"take"}` (nearest visible reachable ground item along gaze), `{type:"put",slot:int}`, `{type:"give",slot:int}` (nearest visible reachable other person), `{type:"speak",text:String}` (max 280 characters). Inventory slots are zero-based private own inventory. Engine resolves spatial targets; command vocabulary never enumerates unseen objects. Extra/unknown fields fail strict parsing. An optional `door` extension may be implemented after core actions.

`GameEvent = {seq:int,tick:int,type:String,actor:String,ok:bool,message:String,details:Dictionary}`. Full events belong to observer/persistence only; own result and spatially audible speech are selectively delivered.

`AgentObservation = {tick:int,self_state:{name,needs,body},inventory:Array[{slot:int,label:String,kind:String}],heard:Array[{speaker:String,text:String,bearing:float,distance:float}],last_result:Dictionary,memory:Array,profile:Dictionary,mock_view:Array}`. `mock_view` contains only geometrically visible `{kind,label,distance,bearing}` entries as diagnostic scaffold; it MUST be omitted from real VLM requests and memory role input. No agent/world IDs or absolute coordinates in observations. PNG bytes passed separately, none for blind agents. Runtime appends only allowlisted personal observations to immutable memory. Observer and global events never enter runtime.

## Map

Floor x=[-9,9], z=[-6,6]. Common west x<2. Storage northeast x>2,z<0. Side room southeast x>2,z>0. Wall at x=2 except storage passage z=[-4.2,-2.2] and closed side door z=[2,3.8]. Divider z=0,x=[2,9]. Wall thickness .2, height 2.8. Geometry wall/door records `{id:String,center:[x,z],size:[width,depth],height:2.8,open:bool}` (`open` only doors). Render and movement/visibility consume these exact rectangles. Room boundary walls included. Observer may hide full walls but per-agent camera keeps them. No secret labels or overlays in camera pixels.

Default start: Ada [4,-3.2], heading=-90 (looks east) near ration [5,-3.2]; Boris [-.5,-3.2], heading=90 (looks west); Cora [-4,2], heading=0. One extra ration/prop in closed side room for occlusion tests; total items conserved. Distinct appearance colors hex without # e.g. e6ae55,65b6d6,c191cf. Profiles stable. `last_ration` scenario puts Ada and Boris near a single accessible ration for contention.

## Ownership and callable APIs

Simulation owns `scripts/simulation/world_simulation.gd` (`class_name WorldSimulation`, RefCounted), tests/test_simulation.gd. `reset(scenario:String="closed_block")->Dictionary`, `snapshot()->Dictionary`, `step(actions:Dictionary,expected_run_id:int=-1)->Array` (one action keyed per agent, stale no-op), `observe(agent_id:String)->Dictionary` (no memory; isolated context), `save_to(path:String)->Error`, `load_from(path:String)->Error` (bumps run), `replay_to(tick:int=-1)->Dictionary` (recorded transitions, no model), `get_state()->Dictionary` or public `state` for debug. Pure helpers for visibility and collisions allowed. Step itself is explicit; root enforces pause. Persistence includes initial state plus complete step records sufficient to restore authoritative state/events.

Runtime owns `scripts/ai/agent_runtime.gd` (`class_name AgentRuntime`, Node), personal_memory.gd, router_adapter.gd and tests/test_runtime.gd. `configure(agent_id:String,profile:Dictionary)`, `reset(run_id:int)`, `decide_mock(observation:Dictionary)->Dictionary`, `remember(observation:Dictionary,image_png:PackedByteArray=PackedByteArray())`, `get_memory()->Array`, `get_debug()->Dictionary`, `build_payload(observation:Dictionary,image_png:PackedByteArray)->Dictionary`, `parse_response(text:String)->Dictionary` returning `{ok:bool,action:Dictionary,error:String}`. Real asynchronous method `request_real(observation,image_png,run_id)` and `decision_ready(agent_id,run_id,tick,action,diagnostic)` signal. Adapter forbids network unless explicit enabled flag AND API key; default off. Use environment key only, never commit secrets. Runtime exposes save/load personal state if feasible.

World/UI owns project.godot (main scene res://scenes/main.tscn, root script res://scripts/main.gd), scenes/, scripts/world/world_view.gd (`class_name WorldView`, Node3D), scripts/ui/observer_ui.gd (`class_name ObserverUI`, CanvasLayer), assets/. `WorldView.setup(state:Dictionary)`, `sync_state(state:Dictionary)`, `capture_agent(agent_id:String)->Image` (caller waits frame_post_draw), `get_agent_texture(agent_id:String)->Texture2D`, `select_agent(id:String)`, `set_view_mode(first_person:bool)`. Agents have own SubViewports and true camera poses. `ObserverUI` signals `run_toggled(running:bool)`, `step_requested`, `reset_requested`, `save_requested`, `load_requested`, `replay_requested`, `agent_selected(id:String)`, `view_toggled(first_person:bool)`. `setup()`, `refresh(state:Dictionary,runtime_debug:Dictionary,events:Array)`, `set_camera_texture(texture:Texture2D)`, `set_running(bool)`, `set_status(text:String)`. Selected default ada. Root wires signals and orchestrates scripts/main.gd.

Root owns integration, docs, launch tools, tests/test_integration.gd, test runner. Do not edit another owner's files; report API changes immediately.
