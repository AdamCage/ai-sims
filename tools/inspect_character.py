import bpy, pathlib
root=pathlib.Path(__file__).resolve().parents[1]
src=root/'test-output/asset-downloads'
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
base=next(src.rglob('Superhero_Female_FullBody.gltf'))
bpy.ops.import_scene.gltf(filepath=str(base))
print('CHARACTER',[(o.name,o.type,tuple(round(v,3) for v in o.dimensions)) for o in bpy.context.scene.objects])
arm=next(o for o in bpy.context.scene.objects if o.type=='ARMATURE')
print('BONES',[(b.name,tuple(round(v,3) for v in b.head_local)) for b in arm.data.bones if b.name in ['root','pelvis','Head','hand_r','foot_r']])
bpy.ops.import_scene.gltf(filepath=str(next(src.rglob('UAL1_Standard.glb'))))
print('ANIMATION_ACTIONS',[(a.name,len(a.slots),[s.identifier for s in a.slots]) for a in bpy.data.actions][:8])
print('ARMATURES',[(o.name,len(o.data.bones)) for o in bpy.context.scene.objects if o.type=='ARMATURE'])
