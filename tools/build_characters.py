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

def attach_armature(obj, arm):
    obj.parent=arm
    mod=obj.modifiers.new('SharedHumanoidSkin','ARMATURE');mod.object=arm

def weights_from_body(obj,body):
    from mathutils.kdtree import KDTree
    tree=KDTree(len(body.data.vertices))
    for v in body.data.vertices:tree.insert(v.co,v.index)
    tree.balance()
    groups={g.index:g.name for g in body.vertex_groups}
    for name in groups.values():obj.vertex_groups.new(name=name)
    for v in obj.data.vertices:
        _,i,_=tree.find(v.co)
        for group in body.data.vertices[i].groups:
            obj.vertex_groups[groups[group.group]].add([v.index],group.weight,'REPLACE')

def piece(name,verts,faces,mat,arm,body,bone=None):
    mesh=bpy.data.meshes.new(name);mesh.from_pydata(verts,[],faces);mesh.update()
    obj=bpy.data.objects.new(name,mesh);bpy.context.collection.objects.link(obj);obj.data.materials.append(mat)
    if bone:
        group=obj.vertex_groups.new(name=bone);group.add(list(range(len(verts))),1,'REPLACE')
    else:weights_from_body(obj,body)
    attach_armature(obj,arm)
    for poly in mesh.polygons:poly.use_smooth=True
    return obj

def box_piece(name,centre,size,mat,arm,body,bone=None):
    x,y,z=centre;a,b,c=[v/2 for v in size]
    verts=[(x+sx*a,y+sy*b,z+sz*c) for sx,sy,sz in [(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]]
    obj=piece(name,verts,[(0,3,2,1),(4,5,6,7),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)],mat,arm,body,bone)
    bpy.context.view_layer.objects.active=obj
    bevel=obj.modifiers.new('SoftTailoredEdges','BEVEL');bevel.width=.007;bevel.segments=2
    bpy.ops.object.modifier_apply(modifier=bevel.name)
    return obj

def ring_piece(name,rings,mat,arm,body,bone=None,start=0,end=math.tau,segments=32):
    verts=[]
    for cx,cy,z,rx,ry in rings:
        for i in range(segments+1):
            angle=start+(end-start)*i/segments
            verts.append((cx+rx*math.sin(angle),cy-ry*math.cos(angle),z))
    faces=[];stride=segments+1
    for r in range(len(rings)-1):
        for i in range(segments):faces.append((r*stride+i,r*stride+i+1,(r+1)*stride+i+1,(r+1)*stride+i))
    return piece(name,verts,faces,mat,arm,body,bone)

def join_parts(parts,name):
    bpy.ops.object.select_all(action='DESELECT')
    for obj in parts:obj.select_set(True)
    bpy.context.view_layer.objects.active=parts[0]
    bpy.ops.object.join();parts[0].name=name
    return parts[0]

def shell(body,name,mat,arm,low,high,reach,puff):
    obj=body.copy();obj.data=body.data.copy();bpy.context.collection.objects.link(obj);obj.name=name
    bm=bmesh.new();bm.from_mesh(obj.data);bmesh.ops.remove_doubles(bm,verts=list(bm.verts),dist=.00005)
    for point,normal in [((0,0,low),(0,0,-1)),((0,0,high),(0,0,1)),((reach,0,0),(1,0,0)),((-reach,0,0),(-1,0,0))]:
        bmesh.ops.bisect_plane(bm,geom=list(bm.verts)+list(bm.edges)+list(bm.faces),dist=.00001,plane_co=point,plane_no=normal,clear_outer=True)
    bmesh.ops.delete(bm,geom=[v for v in bm.verts if not v.link_faces],context='VERTS');bm.normal_update()
    for v in bm.verts:
        v.co+=v.normal*puff
        # Relax the waist into a hanging garment rather than tracing abs/hips.
        if .95<v.co.z<1.35 and abs(v.co.x)<.22:
            v.co.x*=1.06
            if v.co.y<0:v.co.y=min(v.co.y,-.115-puff)
            else:v.co.y=max(v.co.y,.105+puff)
    bm.to_mesh(obj.data);bm.free();obj.data.materials.clear();obj.data.materials.append(mat)
    bpy.context.view_layer.objects.active=obj
    smooth=obj.modifiers.new('RelaxedFabric','SMOOTH');smooth.factor=.45;smooth.iterations=3
    bpy.ops.object.modifier_apply(modifier=smooth.name)
    solid=obj.modifiers.new('ClosedFabricHems','SOLIDIFY');solid.thickness=.007;solid.offset=-.2
    bpy.ops.object.modifier_apply(modifier=solid.name)
    for poly in obj.data.polygons:poly.material_index=0;poly.use_smooth=True
    return obj

for sex in ['Male','Female']:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    source=next(SOURCE.rglob('Superhero_'+sex+'_FullBody.gltf'))
    for image in json.loads(source.read_text()).get('images',[]):
        missing=source.parent/image.get('uri','');fallback=source.parent/image.get('uri','').replace('_png.png','.png')
        if not missing.exists() and fallback.exists():shutil.copyfile(fallback,missing)
    bpy.ops.import_scene.gltf(filepath=str(source))
    main=next(o for o in bpy.context.scene.objects if o.type=='ARMATURE')
    body=max((o for o in bpy.context.scene.objects if o.type=='MESH' and o.parent==main),key=lambda o:len(o.data.vertices));body.name='Body'
    # Soften exaggerated muscle ridges without changing the shared rest skeleton.
    bpy.context.view_layer.objects.active=body
    smooth=body.modifiers.new('EverydayHumanProportions','SMOOTH');smooth.factor=.45;smooth.iterations=3
    bpy.ops.object.modifier_apply(modifier=smooth.name)
    for mat in body.data.materials:
        if mat and mat.use_nodes:
            bs=mat.node_tree.nodes.get('Principled BSDF')
            if bs:
                for link in list(mat.node_tree.links):
                    if link.to_node==bs and link.to_socket==bs.inputs['Normal']:mat.node_tree.links.remove(link)
                bs.inputs['Roughness'].default_value=.82
    shirt=material('Shirt',(.26,.49,.49));pants=material('Trousers',(.16,.21,.28));shoe=material('Shoes',(.15,.17,.20),.82)
    accent=material('Tailoring_Accent',(.88,.85,.76));dark=material('Tailoring_Seams',(.12,.18,.22));buttonmat=material('Tailoring_Buttons',(.63,.58,.43),.5)
    for index,(low,reach,puff) in enumerate([(1.01,.53,.022),(.94,.78,.034),(.92,.77,.03),(1.00,.76,.032)]):
        name='Clothing_Shirt_'+str(index)
        garment=shell(body,name,shirt,main,low,1.545,reach,puff);parts=[garment]
        # Neck binding, sewn pockets and substantial collars are actual geometry.
        parts.append(ring_piece('NeckBinding',[(0,.01,1.52,.085,.078),(0,.01,1.545,.081,.073)],accent,main,body,'spine_03'))
        if index==1:
            # A folded hood around the back of the neck; front opening remains clear.
            parts.append(ring_piece('FoldedHood',[(0,.025,1.45,.13,.13),(0,.035,1.51,.14,.14),(0,.035,1.57,.10,.105)],shirt,main,body,'spine_03',.65,math.tau-.65,26))
            parts.append(box_piece('KangarooPocket',(0,-.154,1.085),(.25,.028,.115),shirt,main,body,'spine_01'))
            for sign in [-1,1]:parts.append(box_piece('HoodCord',(sign*.035,-.137,1.405),(.008,.009,.12),accent,main,body,'spine_03'))
        elif index in [2,3]:
            parts.append(box_piece('FrontPlacket',(0,-.155,1.245),(.025,.021,.42),accent,main,body))
            for sign in [-1,1]:
                parts.append(box_piece('ChestPocket',(sign*.108,-.168,1.335),(.09,.022,.085),shirt,main,body,'spine_03'))
                # Broad lapels distinguish workwear and the coat from a recolored tee.
                lapel=box_piece('Lapel',(sign*.068,-.16,1.455),(.065,.022,.135),accent if index==3 else shirt,main,body,'spine_03');parts.append(lapel)
            for z in [1.11,1.22,1.34,1.43]:parts.append(box_piece('Button',(.018,-.173,z),(.014,.013,.014),buttonmat,main,body))
            if index==3:
                parts.append(ring_piece('CoatSkirt',[(0,.015,1.025,.245,.17),(0,.02,.86,.255,.18),(0,.02,.64,.28,.19)],shirt,main,body,'pelvis',.10,math.tau-.10,40))
                for sign in [-1,1]:parts.append(box_piece('CoatPocket',(sign*.15,-.17,.87),(.12,.025,.115),shirt,main,body,'pelvis'))
        join_parts(parts,name)
    trousers=shell(body,'Clothing_Trousers',pants,main,.14,1.035,2,.019)
    for index in range(2):
        shoes=shell(body,'Clothing_Shoes_'+str(index),shoe,main,-.05,.21 if index==0 else .31,2,.018 if index==0 else .026)
        parts=[shoes]
        # Pale rubber soles and a more substantial ankle make footwear readable.
        for sign,suffix in [(-1,'r'),(1,'l')]:
            parts.append(box_piece('RubberSole',(sign*.11,-.035,.037),(.145,.28,.045),accent,main,body,'foot_'+suffix))
        join_parts(parts,'Clothing_Shoes_'+str(index))
    # Every outfit includes trousers, shoes and a top. Cull only the body that
    # all wardrobe combinations cover, preventing skin clipping while posing.
    skin=bmesh.new();skin.from_mesh(body.data)
    for point,normal in [((0,0,1.51),(0,0,1)),((.50,0,0),(1,0,0)),((-.50,0,0),(1,0,0))]:
        bmesh.ops.bisect_plane(skin,geom=list(skin.verts)+list(skin.edges)+list(skin.faces),dist=.00001,plane_co=point,plane_no=normal)
    hidden=[]
    for face in skin.faces:
        center=face.calc_center_median()
        if center.z<1.51 and abs(center.x)<.50:hidden.append(face)
    bmesh.ops.delete(skin,geom=hidden,context='FACES')
    skin.to_mesh(body.data);skin.free()
    # Four CC0 base hairstyles plus two original derivatives on the same head rig.
    hair_names=['Hair_SimpleParted','Hair_Buns','Hair_Buzzed','Hair_Long'];hair_objects=[]
    for index,name in enumerate(hair_names):
        before=set(bpy.context.scene.objects);hp=next(p for p in SOURCE.rglob(name+'.gltf') if 'Rigged to Head Bone' in str(p))
        bpy.ops.import_scene.gltf(filepath=str(hp));new=set(bpy.context.scene.objects)-before
        for obj in list(new):
            if obj.type=='MESH':
                obj.name='Hair_'+str(index);matrix=obj.matrix_world.copy();obj.parent=main;obj.matrix_world=matrix;hair_objects.append(obj)
                for mod in obj.modifiers:
                    if mod.type=='ARMATURE':mod.object=main
            elif obj.type=='ARMATURE':bpy.data.objects.remove(obj,do_unlink=True)
    bob=hair_objects[3].copy();bob.data=hair_objects[3].data.copy();bpy.context.collection.objects.link(bob);bob.name='Hair_4'
    for v in bob.data.vertices:
        if v.co.z<1.57:v.co.z=1.57+(v.co.z-1.57)*.10
    tied=hair_objects[0].copy();tied.data=hair_objects[0].data.copy();bpy.context.collection.objects.link(tied);tied.name='Hair_5'
    hairmat=tied.data.materials[0] if tied.data.materials else dark
    tail=ring_piece('Ponytail',[(0,.09,1.73,.055,.045),(0,.16,1.70,.052,.05),(0,.22,1.60,.043,.043),(0,.25,1.49,.028,.03),(0,.26,1.43,.01,.01)],hairmat,main,body,'Head')
    join_parts([tied,tail],'Hair_5')
    before=set(bpy.context.scene.objects);bpy.ops.import_scene.gltf(filepath=str(next(SOURCE.rglob('UAL1_Standard.glb'))))
    animations={a.name:a for a in bpy.data.actions if a.name in CLIPS}
    for obj in set(bpy.context.scene.objects)-before:bpy.data.objects.remove(obj,do_unlink=True)
    animations.update(recovery_animations(main));main.animation_data_create();main.animation_data.action=None
    for name in CLIPS:
        action=animations[name];track=main.animation_data.nla_tracks.new();track.name=name;strip=track.strips.new(name,int(action.frame_range[0]),action)
        if action.slots:strip.action_slot=action.slots[0]
    bpy.ops.object.select_all(action='DESELECT');main.select_set(True)
    for obj in main.children_recursive:obj.select_set(True)
    bpy.context.view_layer.objects.active=main;bpy.context.scene.render.fps=30
    for image in bpy.data.images:
        if image.size[0]>1024:image.scale(1024,max(1,int(image.size[1]*1024/image.size[0])))
    target=OUT/('human_'+sex.lower()+'.glb')
    bpy.ops.export_scene.gltf(filepath=str(target),export_format='GLB',use_selection=True,export_animations=True,export_animation_mode='NLA_TRACKS',export_nla_strips=True,export_force_sampling=True,export_frame_range=False,export_yup=True,export_materials='EXPORT',export_image_format='AUTO',export_extras=True)
    print('EXPORTED_ALPHA_HUMAN',target.name,target.stat().st_size)
(OUT/'manifest.json').write_text(json.dumps({'models':['human_male.glb','human_female.glb'],'height_metres':1.78,'animations':CLIPS,'hairstyles':['Hair_'+str(i) for i in range(6)],'outfits':['tee','hoodie','work_jacket','labcoat'],'shoes':['sneakers','boots'],'tint_materials':['Shirt','Trousers','Shoes'],'source':'https://quaternius.com/packs/universalbasecharacters.html','animations_source':'https://quaternius.com/packs/universalanimationlibrary.html','license':'CC0-1.0','modifications':'Original relaxed garments, solid hems, collars, hood, pockets, lapels, shoes, bob and ponytail; softened muscle geometry and normal shading.'},indent=2),encoding='utf8')
