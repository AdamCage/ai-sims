"""Original CC0 furniture for the alpha. Run with Blender 4.5 --background.

Dimensions are metres. Objects are merged by material before glTF export so
small bevels and recognizable fittings do not become hundreds of draw calls.
"""
import bpy, math, json
from pathlib import Path
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets/release/props'
OUT.mkdir(parents=True, exist_ok=True)
PALETTE = {
    'oak': (0.48, .29, .15), 'lightwood': (.69, .49, .29),
    'cream': (.82, .78, .66), 'white': (.77, .83, .79),
    'sage': (.24, .42, .36), 'teal': (.12, .31, .34),
    'navy': (.075, .14, .19), 'metal': (.24, .31, .34),
    'coral': (.68, .30, .22), 'gold': (.72, .52, .22),
    'green': (.19, .36, .18), 'leaf': (.34, .52, .25),
    'screen': (.19, .57, .54), 'paper': (.88, .85, .73),
}

def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    global mats
    mats = {}
    for name, color in PALETTE.items():
        mat=bpy.data.materials.new('Alpha_'+name);mat.diffuse_color=(*color,1);mat.use_nodes=True
        bs=mat.node_tree.nodes.get('Principled BSDF');bs.inputs['Base Color'].default_value=(*color,1)
        bs.inputs['Roughness'].default_value=.72 if name!='screen' else .28
        if name=='metal':bs.inputs['Metallic'].default_value=.35
        if name=='screen':
            bs.inputs['Emission Color'].default_value=(*color,1);bs.inputs['Emission Strength'].default_value=.18
        mats[name]=mat

def finish(obj, color, bevel=.025):
    obj.data.materials.append(mats[color])
    if bevel:
        mod=obj.modifiers.new('Soft manufactured edges','BEVEL');mod.width=bevel;mod.segments=3
        bpy.context.view_layer.objects.active=obj;bpy.ops.object.modifier_apply(modifier=mod.name)
    for face in obj.data.polygons:face.use_smooth=True
    mod=obj.modifiers.new('Weighted corner normals','WEIGHTED_NORMAL');mod.keep_sharp=True;mod.weight=40
    bpy.context.view_layer.objects.active=obj;bpy.ops.object.modifier_apply(modifier=mod.name)
    return obj

def box(size, loc, color='cream', bevel=.025):
    bpy.ops.mesh.primitive_cube_add(size=1,location=loc);obj=bpy.context.object
    obj.dimensions=size;bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
    return finish(obj,color,min(bevel,min(size)*.22))

def cyl(radius, depth, loc, color='metal', vertices=16):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices,radius=radius,depth=depth,location=loc)
    return finish(bpy.context.object,color,.008)

def leaf(loc,scale,color='leaf'):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=10,ring_count=6,radius=1,location=loc)
    obj=bpy.context.object;obj.scale=scale;bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
    return finish(obj,color,0)

def legs(width,depth,height,color='metal'):
    for x in [-width/2+.07,width/2-.07]:
        for y in [-depth/2+.07,depth/2-.07]:box((.065,.065,height),(x,y,height/2),color,.012)

def table(width=1.6,depth=.8,height=.78):
    box((width,depth,.09),(0,0,height-.045),'lightwood');legs(width,depth,height-.09)

def monitor(loc=(0,.14,1.12)):
    x,y,z=loc;box((.64,.065,.4),(x,y,z),'navy');box((.57,.008,.33),(x,y-.037,z),'screen',.012)
    box((.07,.07,.2),(x,y,z-.27),'metal');box((.34,.2,.025),(x,y-.01,z-.38),'metal')
    for i in range(3):box((.38-i*.055,.004,.012),(x-.05,y-.044,z+.065-i*.05),'cream',.002)

def export(name):
    # Shared palette meshes: one primitive per material, not per fitting.
    for mat in mats.values():
        group=[o for o in bpy.context.scene.objects if o.type=='MESH' and o.data.materials and o.data.materials[0]==mat]
        if not group:continue
        bpy.ops.object.select_all(action='DESELECT')
        for o in group:o.select_set(True)
        bpy.context.view_layer.objects.active=group[0];bpy.ops.object.join();group[0].name=mat.name
    bpy.ops.export_scene.gltf(filepath=str(OUT/('alpha_'+name+'.glb')),export_format='GLB',export_animations=False,export_yup=True)
    print('ALPHA_PROP',name)

NAMES=['sofa','chair','bed','medicalbed','locker','wardrobe','shelf','table','desk','console','labdesk','terminal','shop','noticeboard','plant','counter','crate']
for name in NAMES:
    reset()
    if name=='sofa':
        box((2,.83,.24),(0,0,.26),'oak');box((1.7,.68,.24),(0,-.02,.5),'sage',.07)
        box((1.8,.18,.62),(0,.34,.76),'sage',.06)
        for x in [-.94,.94]:box((.19,.83,.55),(x,0,.57),'teal',.06)
        for x in [-.43,.43]:box((.7,.12,.4),(x,.23,.76),'cream',.06)
        legs(1.84,.68,.2)
    elif name=='chair':
        legs(.5,.5,.44);box((.58,.58,.11),(0,0,.48),'sage',.05)
        for x in [-.23,.23]:box((.055,.06,.46),(x,.24,.72),'oak')
        box((.58,.11,.36),(0,.25,.85),'sage',.05)
    elif name in ['bed','medicalbed']:
        box((1.03,2.02,.16),(0,0,.29),'metal');box((1,1.98,.2),(0,0,.48),'cream',.065)
        box((.91,1.25,.075),(0,.25,.61),'teal' if name=='medicalbed' else 'sage',.035)
        box((.75,.38,.14),(0,-.7,.65),'white',.06)
        for y in [-1.01,1.01]:box((1.05,.07,.45),(0,y,.44),'white' if name=='medicalbed' else 'oak')
        legs(.94,1.86,.27)
        if name=='medicalbed':
            for x in [-.54,.54]:
                box((.04,1.2,.035),(x,0,.85),'metal')
                for y in [-.55,.55]:box((.035,.035,.31),(x,y,.7),'metal')
            cyl(.025,1.55,(.7,-.65,.78));box((.32,.025,.025),(.7,-.65,1.54),'metal')
            box((.15,.06,.25),(.79,-.65,1.33),'white')
    elif name in ['locker','wardrobe']:
        box((1.22,.58,1.9),(0,0,.95),'teal' if name=='locker' else 'oak')
        for x in [-.3,.3]:
            box((.57,.045,1.78),(x,-.31,.96),'sage' if name=='locker' else 'lightwood')
            box((.035,.035,.17),(x+.2,-.35,1.05),'gold')
            if name=='locker':
                for z in [1.55,1.61,1.67]:box((.3,.01,.018),(x,-.338,z),'navy',.003)
    elif name=='shelf':
        for x in [-.67,.67]:box((.075,.45,1.88),(x,0,.94),'metal')
        for i in range(4):
            z=.12+i*.54;box((1.4,.48,.07),(0,0,z),'lightwood')
            for j in range(3):box((.24,.32,.27),(-.44+j*.43,.02,z+.175),['coral','sage','cream'][(i+j)%3])
    elif name in ['table','desk','console','labdesk','counter']:
        table(1.6,.85,.8)
        if name in ['desk','console','labdesk']:monitor()
        if name=='desk':
            for i in range(3):box((.26,.34,.018),(-.47,-.13,.856+i*.022),'paper',.006)
        if name=='console':
            box((.51,.26,.035),(0,-.23,.86),'navy')
            for i in range(5):box((.035,.025,.015),(-.18+i*.08,-.24,.885),'cream',.004)
        if name=='labdesk':
            for i in range(3):cyl(.035,.14,(-.5+i*.12,-.12,.94),['coral','screen','gold'][i])
            box((.4,.19,.025),(-.38,-.12,.825),'white')
        if name=='counter':box((1.58,.08,.66),(0,.36,.39),'sage')
    elif name in ['terminal','shop']:
        if name=='terminal':
            box((.72,.62,1.6),(0,0,.8),'teal');box((.58,.04,.43),(0,-.335,1.18),'navy')
            box((.49,.012,.32),(0,-.361,1.18),'screen');box((.42,.075,.18),(0,-.34,.58),'navy')
            box((.3,.12,.035),(0,-.41,.48),'gold');box((.57,.035,.18),(0,-.33,1.5),'cream')
        else:
            box((2,.72,.88),(0,0,.44),'sage');box((2.08,.8,.08),(0,0,.92),'lightwood')
            box((.45,.34,.16),(.56,.1,1.02),'navy');monitor((.56,.15,1.34))
            for i in range(4):box((.19,.22,.07),(-.69+i*.24,-.08,.99),'coral' if i%2 else 'cream')
    elif name=='noticeboard':
        for x in [-.68,.68]:box((.07,.07,1.72),(x,0,.86),'metal')
        box((1.52,.12,.95),(0,0,1.25),'oak');box((1.38,.025,.81),(0,-.075,1.25),'gold')
        box((1.05,.018,.64),(0,-.095,1.25),'paper',.006)
    elif name=='plant':
        cyl(.27,.43,(0,0,.215),'coral');cyl(.022,.85,(0,0,.75),'oak')
        for i in range(9):
            a=i*2.399;z=.68+i*.075
            l=leaf((math.sin(a)*.18,math.cos(a)*.18,z),(.11,.25,.07),'leaf' if i%2 else 'green');l.rotation_euler=(.25,math.sin(a)*.3,-a)
    elif name=='crate':
        box((.7,.52,.5),(0,0,.25),'lightwood')
        for z in [.08,.42]:box((.72,.54,.06),(0,0,z),'oak')
        box((.25,.015,.17),(0,-.275,.28),'paper',.004)
    export(name)

manifest=ROOT/'assets/release/asset_manifest.json'
data=json.loads(manifest.read_text(encoding='utf8'))
for name in NAMES:data['models'][name]='res://assets/release/props/alpha_'+name+'.glb'
for alias,target in {'hospital_bed':'medicalbed','bunk':'bed','cabinet':'wardrobe','network_console':'console','ration_terminal':'terminal'}.items():data['models'][alias]=data['models'][target]
entry={'author':'AI Sims project','url':'tools/build_alpha_props.py','license':'CC0-1.0','description':'Original alpha furniture with rounded fittings and shared palette'}
data['sources']=[s for s in data['sources'] if s.get('url')!=entry['url']]+[entry]
manifest.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
