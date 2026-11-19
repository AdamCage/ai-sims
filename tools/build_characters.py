"""Reproducibly dress/assemble CC0 Quaternius humans and animation clips.
Run with Blender 4.5 LTS --background --python tools/build_characters.py.
Pass an output directory after -- to stage the wardrobe for build_resident_faces.py.
Original archives are downloaded separately into ignored test-output/asset-downloads.
No runtime Blender dependency. All exported assets are standard glTF 2.0.
"""
import bpy, pathlib, shutil, json, math, bmesh, sys
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree

ROOT=pathlib.Path(__file__).resolve().parents[1]
SOURCE=ROOT/'test-output/asset-downloads'
OUT=pathlib.Path(sys.argv[sys.argv.index('--')+1]).resolve() if '--' in sys.argv else ROOT/'assets/release/characters'
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

def weights_from_body(obj,body,samples=1):
    from mathutils.kdtree import KDTree
    tree=KDTree(len(body.data.vertices))
    for v in body.data.vertices:tree.insert(v.co,v.index)
    tree.balance()
    groups={g.index:g.name for g in body.vertex_groups}
    for name in groups.values():obj.vertex_groups.new(name=name)
    for v in obj.data.vertices:
        if samples==1:
            _,i,_=tree.find(v.co)
            for group in body.data.vertices[i].groups:
                obj.vertex_groups[groups[group.group]].add([v.index],group.weight,'REPLACE')
            continue
        weights={}
        for _,index,distance in tree.find_n(v.co,samples):
            falloff=1.0/max(.009,distance)**2
            for group in body.data.vertices[index].groups:
                weights[group.group]=weights.get(group.group,0.)+group.weight*falloff
        strongest=sorted(weights.items(),key=lambda item:item[1],reverse=True)[:4]
        total=sum(value for _,value in strongest)
        for index,value in strongest:
            obj.vertex_groups[groups[index]].add([v.index],value/total,'REPLACE')

def piece(name,verts,faces,mat,arm,body,bone=None,weight_samples=1):
    mesh=bpy.data.meshes.new(name);mesh.from_pydata(verts,[],faces);mesh.update()
    obj=bpy.data.objects.new(name,mesh);bpy.context.collection.objects.link(obj);obj.data.materials.append(mat)
    if bone:
        group=obj.vertex_groups.new(name=bone);group.add(list(range(len(verts))),1,'REPLACE')
    else:weights_from_body(obj,body,weight_samples)
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
    obj=piece(name,verts,faces,mat,arm,body,bone)
    uv=obj.data.uv_layers.new(name='Fabric UV')
    for loop in obj.data.loops:
        row,column=divmod(loop.vertex_index,stride)
        uv.data[loop.index].uv=(column/segments,row/(len(rings)-1))
    return obj


def tailored_top(body, mat, arm, female, outfit):
    """Draft the bodice and both sleeves as a single skinned garment."""
    segments = 40
    shoulder = -.031 if female else 0.0
    waist = .242 if female else .234
    ease = (.0, .018, .012, .016)[outfit]
    length = (.0, .010, .025, .0)[outfit]
    profiles = [
        (1.003 - length, waist, .190), (1.013 - length, waist + .004, .190),
        (1.066, waist - .009, .173), (1.171, .192, .151),
        (1.289, .221, .152), (1.341 + shoulder, .227, .142),
        (1.421 + shoulder, .232, .127), (1.502 + shoulder, .222, .111),
        (1.537 + shoulder, .185, .088), (1.531, .083, .078), (1.546, .069, .064),
    ]
    coat_rows = 0
    if outfit == 3:
        # A continuous side and back avoid an overlap seam opening above the
        # thigh. The split at the front leaves room for both legs to bend.
        profiles = [(.846, .247, .184), (.856, .250, .187),
                    (.910, .252, .192), (.971, .247, .193)] + profiles
        coat_rows = 4
    low, high = 5 + coat_rows, 8 + coat_rows
    armhole_centers = (segments//4, 3*segments//4)
    armholes = [(center-4, center+4) for center in armhole_centers]
    vertices, faces, uv_points = [], [], []
    for row,(z,width,depth) in enumerate(profiles):
        for column in range(segments):
            theta = column*math.tau/segments
            sin,cos = math.sin(theta),math.cos(theta)
            torso_row = row - coat_rows
            roundness = .64 if torso_row<=2 else (.79 if torso_row<=4 else 1.0)
            cut = 1.0 if torso_row<9 else .20
            fall = max(0.0, 1.0-abs(torso_row-2.0)/4.0)
            # Long waves interrupt evenly inflated silhouettes without steering the seams.
            fold = fall*(.005*math.sin(theta*5.0+z*15.0)+.003*math.sin(theta*8.0-z*22.0))
            x = math.copysign(abs(sin)**roundness,sin)*(width+ease*cut+fold)
            y = .012-math.copysign(abs(cos)**roundness,cos)*(depth+ease*cut+fold)
            # The crew collar slopes down at the front.
            vertices.append((x,y,z-.016*max(0.0,cos) if torso_row>=9 else z))
            uv_points.append((column/segments,(z-profiles[0][0])*.86))
    for row in range(len(profiles)-1):
        for column in range(segments):
            if low<=row<high and any(start<=column<end for start,end in armholes):
                continue
            if outfit == 3 and row < coat_rows and column in (0, segments-1):
                continue
            next_column = (column+1)%segments
            faces.append((row*segments+column,row*segments+next_column,
                          (row+1)*segments+next_column,(row+1)*segments+column))

    for side,(start,end) in zip((1,-1),armholes):
        rim = [low*segments+col for col in range(start,end+1)]
        rim += [row*segments+end for row in range(low+1,high+1)]
        rim += [high*segments+col for col in range(end-1,start-1,-1)]
        rim += [row*segments+start for row in range(high-1,low,-1)]
        center_y = .032
        center_z = (profiles[low][0]+profiles[high][0])*.5
        angles = [math.atan2((vertices[index][1]-center_y)/.074,
                             (vertices[index][2]-center_z)/.093) for index in rim]
        previous = rim
        if female:
            stations = [(.237,.051,1.409,.086,.085),(.320,.053,1.416,.063,.065),
                        (.416,.052,1.417,.058,.060),(.477,.053,1.417,.052,.055),
                        (.522,.053,1.415,.047,.051)]
            cuffs = [(.552,.054,1.418,.043,.046),(.590,.056,1.417,.040,.042),
                     (.611,.058,1.417,.036,.039),(.619,.059,1.417,.035,.038)]
        else:
            stations = [(.279,.080,1.446,.097,.094),(.357,.073,1.437,.078,.076),
                        (.427,.081,1.441,.072,.079),(.482,.084,1.441,.064,.073),
                        (.538,.082,1.443,.059,.069)]
            cuffs = [(.571,.081,1.445,.053,.061),(.620,.074,1.446,.046,.051),
                     (.662,.071,1.448,.039,.043),(.675,.071,1.449,.036,.040)]
        if outfit:
            stations += cuffs
        else:
            x,y,z,ry,rz = stations[-1]
            stations.append((x+.006,y,z,ry-.004,rz-.004))
        for step,(x,y,z,y_radius,z_radius) in enumerate(stations,1):
            ring = []
            for col,angle in enumerate(angles):
                ring.append(len(vertices))
                sleeve_ease = ease if step<7 else ease*.5
                tuck = .003*math.sin(angle*3.0+x*17.0)*(1.0-1.0/step)
                vertices.append((x*side,y+(y_radius+sleeve_ease+tuck)*math.sin(angle),
                                 z+(z_radius+sleeve_ease+tuck)*math.cos(angle)))
                uv_points.append((col/len(rim),.51+step*.056))
            for col in range(len(rim)):
                following = (col+1)%len(rim)
                faces.append((previous[col],ring[col],ring[following],previous[following]))
            previous = ring

    shirt = piece(f'Clothing_Shirt_{outfit}',vertices,faces,mat,arm,body,weight_samples=6)
    uv = shirt.data.uv_layers.new(name='Fabric UV')
    for polygon in shirt.data.polygons:
        points = [uv_points[shirt.data.loops[loop].vertex_index] for loop in polygon.loop_indices]
        crosses_seam = max(u for u,_ in points)-min(u for u,_ in points)>.5
        for loop,(u,v) in zip(polygon.loop_indices,points):
            uv.data[loop].uv = (u+1.0 if crosses_seam and u<.5 else u,v)
    mesh = bmesh.new()
    mesh.from_mesh(shirt.data)
    bmesh.ops.delete(mesh,geom=[v for v in mesh.verts if not v.link_faces],context='VERTS')
    bmesh.ops.recalc_face_normals(mesh,faces=list(mesh.faces))
    mesh.to_mesh(shirt.data)
    mesh.free()
    if outfit:
        # The distal sleeve follows the forearm. The hand can bend or grip
        # inside the opening without pulling the fabric onto the knuckles.
        cuff_start = .563 if female else .592
        cuff_end = .604 if female else .651
        for vertex in shirt.data.vertices:
            x = vertex.co.x
            amount = smooth_range(cuff_start, cuff_end, abs(x))
            if amount <= 0.0:
                continue
            forearm = shirt.vertex_groups['lowerarm_l' if x > 0.0 else 'lowerarm_r']
            weights = {group.group: group.weight * (1.0 - amount) for group in vertex.groups}
            weights[forearm.index] = weights.get(forearm.index, 0.0) + amount
            for group in list(vertex.groups):
                shirt.vertex_groups[group.group].remove([vertex.index])
            for group, weight in weights.items():
                if weight > .00001:
                    shirt.vertex_groups[group].add([vertex.index], weight, 'REPLACE')
    bpy.context.view_layer.objects.active = shirt
    rim = shirt.modifiers.new('Bound fabric edges','SOLIDIFY')
    rim.thickness = (.003,.006,.005,.005)[outfit]
    bpy.ops.object.modifier_apply(modifier=rim.name)
    if outfit == 3:
        pelvis=shirt.vertex_groups['pelvis']
        for vertex in shirt.data.vertices:
            x,_,z=vertex.co
            if z>=1.055:
                continue
            for group in list(vertex.groups):
                shirt.vertex_groups[group.group].remove([vertex.index])
            influence=.18*smooth_range(1.055, .846, z)
            left=max(0.0,min(1.0,.5+x/.18))
            pelvis.add([vertex.index],1.0-influence,'REPLACE')
            for name,blend in [('thigh_r',1.0-left),('thigh_l',left)]:
                if blend*influence>.0001:
                    shirt.vertex_groups[name].add([vertex.index],blend*influence,'REPLACE')
    return shirt


def smooth_range(start, end, value):
    t = max(0.0, min(1.0, (value - start) / (end - start)))
    return t * t * (3.0 - 2.0 * t)


def seated_trouser_fold(x, y, z):
    hips = max(0.0,1.0-abs(z-.827)/.175)
    front = max(0.0,min(1.0,(-y+.02)*7.0))
    lateral = max(0.0,min(1.0,(abs(x)-.12)*9.0))
    # The shirt's lower edge sits over the upper thigh. The trousers flatten
    # under that edge and keep their fold farther down towards the knee.
    compression = smooth_range(.85, .95, z) * (1.0 - smooth_range(1.015, 1.109, z))
    return Vector((math.copysign(hips*lateral*.007,x),
        front*(compression*.036 - hips*(.014+.007*math.sin(z*82.0+abs(x)*8.0))),0.0))


def cloth_correctives(obj, outfit=None):
    """Shape the loose outer cloth where a seated or moving joint compresses it."""
    obj.shape_key_add(name='Basis')
    if outfit is None:
        seated = obj.shape_key_add(name='SeatedSlack')
        cuff = obj.shape_key_add(name='CuffFlex')
        for vertex in obj.data.vertices:
            i = vertex.index
            _,y,z = vertex.co
            # The outer thigh tightens while a small fold moves towards the knee.
            seated.data[i].co += seated_trouser_fold(*vertex.co)
            hem = max(0.0,1.0-abs(z-.205)/.075)
            cuff.data[i].co.y += hem*(y-.07)*.11
        return
    shoulder = obj.shape_key_add(name='ShoulderEase')
    seated = obj.shape_key_add(name='SeatedSlack')
    cuff = obj.shape_key_add(name='CuffFlex')
    for vertex in obj.data.vertices:
        i = vertex.index
        x,y,z = vertex.co
        joint = max(0.0,1.0-abs(abs(x)-.245)/.13)
        cap = max(0.0,1.0-abs(z-1.415)/.14)*joint
        shoulder.data[i].co.x += math.copysign(cap*.013,x)
        shoulder.data[i].co.y += (y-.035)*cap*.11
        hip = max(0.0,1.0-abs(z-1.036)/.17) if outfit != 3 else max(0.0,min(1.0,(1.17-z)*3.4))
        front = max(0.0,min(1.0,(-y+.05)*6.0))
        seated.data[i].co.y -= front*hip*(.021+.008*math.sin(z*61.0+abs(x)*14.0))
        seated.data[i].co.z += front*hip*(.023 if outfit == 3 else .013)
        seated.data[i].co.x += math.copysign(hip*.007,x)
        waist = 1.158 if outfit == 3 else 1.145
        if z < waist:
            front_panel = smooth_range(-.04, .10, -y)
            compression = (.81 + .06 * front_panel) if outfit == 3 else (.54 + .13 * front_panel)
            # Compress the vertical spacing towards the waist without
            # inverting the edge loops during a deep bend.
            seated.data[i].co.z = z + (waist - z) * compression
            if outfit == 3:
                gather = smooth_range(waist, .846, z)
                seated.data[i].co.z += .033 * (waist - z) / (waist - .846) * front_panel
                seated.data[i].co.y += .028 * gather * front_panel
                seated.data[i].co.x -= math.copysign(.010 * gather * front_panel, x)
        forearm = smooth_range(.39, .58, abs(x))
        cuff.data[i].co.z += (z-1.435)*forearm*.09
        cuff.data[i].co.y += (y-.055)*forearm*.08

def join_parts(parts,name):
    bpy.ops.object.select_all(action='DESELECT')
    for obj in parts:obj.select_set(True)
    bpy.context.view_layer.objects.active=parts[0]
    bpy.ops.object.join();parts[0].name=name
    return parts[0]


def tailoring_surface(garment):
    mesh = garment.data
    vertices = [vertex.co for vertex in mesh.vertices]
    return BVHTree.FromPolygons(vertices,[list(face.vertices) for face in mesh.polygons])


def front_y(surface, x, z):
    hit, _, _, _ = surface.ray_cast(Vector((x,-1.0,z)),Vector((0.0,1.0,0.0)),2.0)
    if hit is None:
        raise ValueError(f'Tailoring pattern outside bodice at ({x:.3f}, {z:.3f})')
    return hit.y


def sewn_panel(name, pattern, surface, garment, mat, arm, relief=.006):
    vertices = [(x,front_y(surface,x,z)-relief,z) for x,z in pattern]
    sides = len(vertices)
    garment_panel = piece(name,vertices,[tuple(range(sides))],mat,arm,garment,weight_samples=4)
    uv = garment_panel.data.uv_layers.new(name='Fabric UV')
    for loop in garment_panel.data.loops:
        x,_,z = vertices[loop.vertex_index]
        uv.data[loop.index].uv = (.5+x,z*.86)
    bpy.context.view_layer.objects.active=garment_panel
    hem=garment_panel.modifiers.new('Sewn edge','SOLIDIFY')
    hem.thickness=.004
    bpy.ops.object.modifier_apply(modifier=hem.name)
    return garment_panel

def shell(body,name,mat,arm,low,high,reach,puff,thick=True):
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
    if thick:
        fabric_lining(obj,.007)
    for poly in obj.data.polygons:poly.material_index=0;poly.use_smooth=True
    return obj


def fabric_lining(obj, thickness):
    bpy.context.view_layer.objects.active=obj
    solid=obj.modifiers.new('ClosedFabricHems','SOLIDIFY')
    solid.thickness=thickness
    solid.offset=-1.0
    bpy.ops.object.modifier_apply(modifier=solid.name)


def taper_waistband(trousers):
    """Keep the raised front tucked under the shirt and lower the back edge."""
    for vertex in trousers.data.vertices:
        x, y, z = vertex.co
        band = smooth_range(1.030, 1.112, z)
        if band <= 0.0:
            continue
        front = smooth_range(.012, -.105, y)
        vertex.co.z = 1.030 + (z - 1.030) * (.065 + .935 * front)
        vertex.co.x = x * (1.0 - .070 * band)
        vertex.co.y = .012 + (y - .012) * (1.0 - .105 * band)


def fitted_sole(side, boot, female, mat, arm, body):
    """Build the rubber tread from the rounded foot's profile and skin weights."""
    sections=[(-.143,.102,.026),(-.121,.119,.051),(-.073,.137,.063),
              (-.019,.131,.049),(.034,.125,.042),(.101,.119,.047),
              (.135,.117,.033),(.147,.117,.014)]
    if female:
        sections=[(y-(.006 if y>0 else .003),x-.006,w) for y,x,w in sections]
    outline = [(side*(x-w),y) for y,x,w in sections]
    outline += [(side*(x+w),y) for y,x,w in reversed(sections)]
    vertices,faces=[],[]
    center=Vector((side*.117,.008,0.0))
    for z,taper in [(-.009,.86),(-.005,1.0),(.013,1.0),(.023 if boot else .018,.92)]:
        vertices.extend((center.x+(x-center.x)*taper,center.y+(y-center.y)*taper,z) for x,y in outline)
    n=len(outline)
    for ring in range(3):
        for i in range(n):
            a=ring*n+i
            b=ring*n+(i+1)%n
            faces.append((a,b,b+n,a+n))
    faces.extend([tuple(range(n-1,-1,-1)),tuple(range(3*n,4*n))])
    result=piece('RubberSole',vertices,faces,mat,arm,body,weight_samples=4)
    connected=bmesh.new()
    connected.from_mesh(result.data)
    bmesh.ops.recalc_face_normals(connected,faces=list(connected.faces))
    connected.to_mesh(result.data)
    connected.free()
    return result


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
    # The waistband remains covered in standing poses and backs the top
    # when the hips compress the cloth in a seated pose.
    trousers=shell(body,'Clothing_Trousers',pants,main,.14,1.115,2,.019,thick=False)
    taper_waistband(trousers)
    fabric_lining(trousers,.007)
    cloth_correctives(trousers)
    for index in range(4):
        name='Clothing_Shirt_'+str(index)
        garment=tailored_top(body,shirt,main,sex=='Female',index)
        parts=[garment]
        front=tailoring_surface(garment)
        if index==1:
            parts.append(ring_piece('FoldedHood',[(0,.036,1.455,.125,.123),(0,.057,1.49,.142,.142),
                (0,.071,1.53,.135,.122),(0,.050,1.565,.090,.065)],shirt,main,body,'spine_03',.84,math.tau-.84,32))
            pouch = [(-.122,1.069),(.122,1.069),(.127,1.123),(.091,1.158),(-.091,1.158),(-.127,1.123)]
            parts.append(sewn_panel('KangarooPocket',pouch,front,garment,shirt,main,.008))
            for sign in [-1,1]:
                cord=[(sign*x,z) for x,z in [(.029,1.461),(.034,1.461),(.044,1.375),(.039,1.375)]]
                parts.append(sewn_panel('HoodCord',cord,front,garment,accent,main,.006))
        elif index in [2,3]:
            for low,high in [(1.08,1.19),(1.19,1.30),(1.30,1.40),(1.40,1.47)]:
                placket=[(-.008,low),(.008,low),(.008,high),(-.008,high)]
                parts.append(sewn_panel('FrontPlacket',placket,front,garment,shirt,main,.009))
            for sign in [-1,1]:
                z=1.327 if sex=='Male' else 1.306
                patch=[(sign*x,z+dz) for x,dz in [(.072,-.031),(.130,-.031),(.145,-.013),(.145,.031),(.072,.031)]]
                parts.append(sewn_panel('ChestPocket',patch,front,garment,shirt,main))
                if index==3:
                    fold=[(sign*x,z) for x,z in [(.052,1.493),(.091,1.498),(.100,1.452),
                          (.079,1.442),(.026,1.339),(.039,1.434)]]
                    parts.append(sewn_panel('Lapel',fold,front,garment,shirt,main,.008))
            for z in [1.12,1.23,1.34,1.449]:
                parts.append(box_piece('Button',(.016,front_y(front,.016,z)-.008,z),
                    (.009,.006,.009),buttonmat,main,garment))
            if index==3:
                for sign in [-1,1]:
                    patch=[(sign*x,z) for x,z in [(.084,1.058),(.160,1.058),(.175,1.121),(.084,1.121)]]
                    parts.append(sewn_panel('CoatPocket',patch,front,garment,shirt,main))
        garment=join_parts(parts,name) if len(parts)>1 else garment
        cloth_correctives(garment,index)
    for index in range(2):
        shoes=shell(body,'Clothing_Shoes_'+str(index),shoe,main,-.05,.21 if index==0 else .31,2,.018 if index==0 else .026)
        parts=[shoes]
        for sign in [-1,1]:
            parts.append(fitted_sole(sign,index==1,sex=='Female',dark,main,body))
        join_parts(parts,'Clothing_Shoes_'+str(index))
    # Every outfit includes trousers, shoes and a top. Cull only the body that
    # all wardrobe combinations cover, preventing skin clipping while posing.
    skin=bmesh.new();skin.from_mesh(body.data)
    for point,normal in [((0,0,1.51),(0,0,1)),((.50,0,0),(1,0,0)),((-.50,0,0),(1,0,0))]:
        bmesh.ops.bisect_plane(skin,geom=list(skin.verts)+list(skin.edges)+list(skin.faces),dist=.00001,plane_co=point,plane_no=normal)
    hidden=[]
    for face in skin.faces:
        center=face.calc_center_median()
        if abs(center.x)<.50 and (center.z<1.51 or abs(center.x)>.215):
            hidden.append(face)
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
(OUT/'manifest.json').write_text(json.dumps({'models':['human_male.glb','human_female.glb'],'height_metres':1.78,'animations':CLIPS,'hairstyles':['Hair_'+str(i) for i in range(6)],'outfits':['tee','hoodie','work_jacket','labcoat'],'shoes':['sneakers','boots'],'tint_materials':['Shirt','Trousers','Shoes'],'source':'https://quaternius.com/packs/universalbasecharacters.html','animations_source':'https://quaternius.com/packs/universalanimationlibrary.html','license':'CC0-1.0','modifications':'Original relaxed garments with skinned linings, solid hems, collars, hood, pockets and lapels, low-profile shoe soles, bob and ponytail; softened muscle geometry and normal shading.'},indent=2),encoding='utf8')
