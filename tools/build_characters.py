"""Reproducibly dress/assemble CC0 Quaternius humans and animation clips.
Run with Blender 4.5 LTS --background --python tools/build_characters.py.
Original archives are downloaded separately into ignored test-output/asset-downloads.
No runtime Blender dependency. All exported assets are standard glTF 2.0.
"""
import bpy, pathlib, shutil, json, math, bmesh
from mathutils import Vector, Matrix

ROOT=pathlib.Path(__file__).resolve().parents[1]
SOURCE=ROOT/'test-output/asset-downloads'
OUT=ROOT/'assets/release/characters'
OUT.mkdir(parents=True,exist_ok=True)
CLIPS=['Idle_Loop','Walk_Loop','Jog_Fwd_Loop','Sword_Attack','Sword_Idle','PickUp_Table','Interact','Death01','Fixing_Kneeling','Sitting_Idle_Loop','Idle_Talking_Loop','Crouch_Fwd_Loop','Crouch_Idle_Loop','Hit_Chest','Hit_Head','Sitting_Enter','Sitting_Exit','Push_Loop','Punch_Jab','Sleep_Loop','Crawl_Loop']

def recovery_animations(arm):
    """Original resting and hands-and-knees crawling poses on the shared rig."""
    result={}
    arm.animation_data_create()
    for name in ['Sleep_Loop','Crawl_Loop']:
        for bone in arm.pose.bones:
            bone.rotation_mode='QUATERNION';bone.rotation_quaternion=(1,0,0,0);bone.location=(0,0,0);bone.scale=(1,1,1)
        action=bpy.data.actions.new(name);arm.animation_data.action=action
        for frame in [0,15,30,45,60]:
            bpy.context.scene.frame_set(frame)
            wave=math.sin(frame/60*2*math.pi)*.11 if name=='Crawl_Loop' else 0
            if name=='Sleep_Loop':
                joints={'pelvis':((0,.12,.21),(0,-.02,.24)),'spine_01':((0,-.02,.24),(0,-.19,.26)),'spine_02':((0,-.19,.26),(0,-.35,.26)),'spine_03':((0,-.35,.26),(0,-.51,.27)),'neck_01':((0,-.51,.27),(0,-.62,.28)),'Head':((0,-.62,.28),(0,-.78,.28))}
                for sign,suffix in [(1,'l'),(-1,'r')]:
                    joints.update({'clavicle_'+suffix:((0,-.40,.27),(sign*.20,-.40,.25)),'upperarm_'+suffix:((sign*.20,-.40,.25),(sign*.34,-.12,.14)),'lowerarm_'+suffix:((sign*.34,-.12,.14),(sign*.34,.15,.12)),'hand_'+suffix:((sign*.34,.15,.12),(sign*.34,.25,.12)),'thigh_'+suffix:((sign*.11,.10,.20),(sign*.13,.54,.14)),'calf_'+suffix:((sign*.13,.54,.14),(sign*.13,.94,.11)),'foot_'+suffix:((sign*.13,.94,.11),(sign*.13,1.06,.15))})
            else:
                joints={'pelvis':((0,.43,.45),(0,.30,.49)),'spine_01':((0,.30,.49),(0,.13,.53)),'spine_02':((0,.13,.53),(0,-.02,.56)),'spine_03':((0,-.02,.56),(0,-.18,.58)),'neck_01':((0,-.18,.58),(0,-.25,.61)),'Head':((0,-.25,.61),(0,-.25,.79))}
                for sign,suffix in [(1,'l'),(-1,'r')]:
                    move=wave*sign
                    joints.update({'clavicle_'+suffix:((0,-.12,.57),(sign*.20,-.12,.55)),'upperarm_'+suffix:((sign*.20,-.12,.55),(sign*.28,-.23+move*.5,.31)),'lowerarm_'+suffix:((sign*.28,-.23+move*.5,.31),(sign*.28,-.47+move,.075)),'hand_'+suffix:((sign*.28,-.47+move,.075),(sign*.28,-.58+move,.055)),'thigh_'+suffix:((sign*.11,.43,.44),(sign*.19,.66-move,.11)),'calf_'+suffix:((sign*.19,.66-move,.11),(sign*.20,1.03-move,.11)),'foot_'+suffix:((sign*.20,1.03-move,.11),(sign*.20,1.14-move,.08))})
            for bone_name,(head,tail) in joints.items():
                bone=arm.pose.bones.get(bone_name)
                if bone is None:continue
                direction=Vector(tail)-Vector(head)
                transform=Matrix.Translation(Vector(head))@direction.to_track_quat('Y','Z').to_matrix().to_4x4()
                bone.matrix=transform
                bpy.context.view_layer.update()
            for bone in arm.pose.bones:
                bone.keyframe_insert('location',frame=frame);bone.keyframe_insert('rotation_quaternion',frame=frame);bone.keyframe_insert('scale',frame=frame)
        result[name]=action
    arm.animation_data.action=None
    return result

def material(name,color,rough=.75):
    m=bpy.data.materials.new(name);m.diffuse_color=(*color,1);m.use_nodes=True
    bs=m.node_tree.nodes.get('Principled BSDF');bs.inputs['Base Color'].default_value=(*color,1);bs.inputs['Roughness'].default_value=rough
    texpath=ROOT/'assets/release/textures/fabric_color.png'
    if texpath.exists() and name in ['Shirt','Trousers']:
        tex=m.node_tree.nodes.new('ShaderNodeTexImage');tex.image=bpy.data.images.load(str(texpath),check_existing=True)
        mix=m.node_tree.nodes.new('ShaderNodeMixRGB');mix.blend_type='MULTIPLY';mix.inputs[0].default_value=.28;mix.inputs[1].default_value=(*color,1)
        m.node_tree.links.new(tex.outputs['Color'],mix.inputs[2]);m.node_tree.links.new(mix.outputs['Color'],bs.inputs['Base Color'])
    return m

for sex in ['Male','Female']:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    source=next(SOURCE.rglob('Superhero_'+sex+'_FullBody.gltf'))
    # The author's free package contains one incorrectly named normal-map URI.
    for image in json.loads(source.read_text()).get('images',[]):
        missing=source.parent/image.get('uri','')
        fallback=source.parent/image.get('uri','').replace('_png.png','.png')
        if not missing.exists() and fallback.exists():shutil.copyfile(fallback,missing)
    bpy.ops.import_scene.gltf(filepath=str(source))
    main=next(o for o in bpy.context.scene.objects if o.type=='ARMATURE')
    body=max((o for o in bpy.context.scene.objects if o.type=='MESH' and o.parent==main),key=lambda o:len(o.data.vertices))
    body.name='Body'
    # Real skin/eye normal+color textures remain intact; clothe body with mesh shells.
    shirt=material('Shirt',(.20,.42,.46));pants=material('Trousers',(.10,.14,.21));shoes=material('Shoes',(.055,.065,.085),.4)
    for name,mat,planes in [
        ('Clothing_Shirt',shirt,[((0,0,.98),(0,0,-1)),((0,0,1.57),(0,0,1)),((.56,0,0),(1,0,0)),((-.56,0,0),(-1,0,0))]),
        ('Clothing_Trousers',pants,[((0,0,.14),(0,0,-1)),((0,0,1.035),(0,0,1))]),
        ('Clothing_Shoes',shoes,[((0,0,.19),(0,0,1))])]:
        obj=body.copy();obj.data=body.data.copy();bpy.context.collection.objects.link(obj);obj.name=name
        bm=bmesh.new();bm.from_mesh(obj.data)
        # Exact planar cuts produce continuous cuffs and hems. Selecting whole
        # source triangles by their centres creates the old serrated boundaries.
        bmesh.ops.remove_doubles(bm,verts=list(bm.verts),dist=.00005)
        for point,normal in planes:
            bmesh.ops.bisect_plane(bm,geom=list(bm.verts)+list(bm.edges)+list(bm.faces),dist=.00001,plane_co=point,plane_no=normal,clear_outer=True)
        bmesh.ops.delete(bm,geom=[v for v in bm.verts if not v.link_faces],context='VERTS')
        bm.normal_update()
        # Slightly expand garments, retaining real topology and deform weights.
        for v in bm.verts:v.co+=v.normal*(.019 if name=='Clothing_Shirt' else .014)
        bm.to_mesh(obj.data);bm.free();obj.data.materials.clear();obj.data.materials.append(mat)
        for p in obj.data.polygons:p.material_index=0;p.use_smooth=True
    # All free hairstyles share the same humanoid joints as the base models.
    hair_names=['Hair_SimpleParted','Hair_Buns','Hair_Buzzed','Hair_Long']
    for index,name in enumerate(hair_names):
        before=set(bpy.context.scene.objects)
        hp=next(p for p in SOURCE.rglob(name+'.gltf') if 'Rigged to Head Bone' in str(p))
        bpy.ops.import_scene.gltf(filepath=str(hp))
        new=set(bpy.context.scene.objects)-before
        for obj in list(new):
            if obj.type=='MESH':
                obj.name='Hair_'+str(index);matrix=obj.matrix_world.copy();obj.parent=main;obj.matrix_world=matrix
                for mod in obj.modifiers:
                    if mod.type=='ARMATURE':mod.object=main
            elif obj.type=='ARMATURE':
                bpy.data.objects.remove(obj,do_unlink=True)
    before=set(bpy.context.scene.objects)
    bpy.ops.import_scene.gltf(filepath=str(next(SOURCE.rglob('UAL1_Standard.glb'))))
    animations={a.name:a for a in bpy.data.actions if a.name in CLIPS}
    for obj in set(bpy.context.scene.objects)-before:bpy.data.objects.remove(obj,do_unlink=True)
    animations.update(recovery_animations(main))
    main.animation_data_create();main.animation_data.action=None
    for name in CLIPS:
        action=animations[name];track=main.animation_data.nla_tracks.new();track.name=name
        strip=track.strips.new(name,int(action.frame_range[0]),action)
        if action.slots:strip.action_slot=action.slots[0]
    # Export the hierarchy only: exclude importer helper meshes and source mannequin.
    bpy.ops.object.select_all(action='DESELECT');main.select_set(True)
    for obj in main.children_recursive:obj.select_set(True)
    bpy.context.view_layer.objects.active=main
    bpy.context.scene.render.fps=30
    for image in bpy.data.images:
        if image.size[0]>1024:image.scale(1024,max(1,int(image.size[1]*1024/image.size[0])))
    target=OUT/('human_'+sex.lower()+'.glb')
    bpy.ops.export_scene.gltf(filepath=str(target),export_format='GLB',use_selection=True,export_animations=True,export_animation_mode='NLA_TRACKS',export_nla_strips=True,export_force_sampling=True,export_frame_range=False,export_yup=True,export_materials='EXPORT',export_image_format='AUTO',export_extras=True)
    print('EXPORTED_HUMAN',target.name,target.stat().st_size)
(OUT/'manifest.json').write_text(json.dumps({'models':['human_male.glb','human_female.glb'],'height_metres':1.78,'animations':CLIPS,'hairstyles':['Hair_'+str(i) for i in range(4)],'tint_materials':['Shirt','Trousers','Shoes'],'source':'https://quaternius.com/packs/universalbasecharacters.html','animations_source':'https://quaternius.com/packs/universalanimationlibrary.html','license':'CC0-1.0'},indent=2),encoding='utf8')
