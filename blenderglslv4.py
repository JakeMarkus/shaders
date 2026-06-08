bl_info = {
    "name": "Simple Custom Viewport Shader Overlay",
    "blender": (5, 1, 2),
    "category": "3D View",
}

import os
import re
import bpy
import gpu
import datetime
from gpu_extras.batch import batch_for_shader
from bpy.props import (
    BoolProperty,
    FloatVectorProperty,
    StringProperty,
    PointerProperty,
    CollectionProperty,
    IntProperty,
    EnumProperty,
    FloatProperty,
)


# Separate handles for the two draw stages:
#   _draw_handle_view  – POST_VIEW  : mesh objects (depth-tested against the live scene)
#   _draw_handle_pixel – POST_PIXEL : background quad (screen-space, drawn after everything)
_draw_handle_view  = None
_draw_handle_pixel = None
_bg_shader = None

# folder_path -> {"shader": GPUShader or None, "error": str}
_shader_cache = {}

# Name of the shared invisible material we create and manage
_GHOST_MAT_NAME = ".SimplShader_Ghost"


# ------------------------------------------------------------
# Shadertoy compatibility
# ------------------------------------------------------------

# Shadertoy built-in uniform names that we provide
_SHADERTOY_BUILTIN_NAMES = {
    "iTime", "iTimeDelta", "iFrame", "iFrameRate",
    "iResolution", "iMouse", "iDate",
    "iChannel0", "iChannel1", "iChannel2", "iChannel3",
    "iSampleRate",
}

_SHADERTOY_PREAMBLE = """\
// --- Shadertoy compatibility uniforms ---
uniform float     iTime;
uniform float     iTimeDelta;
uniform int       iFrame;
uniform float     iFrameRate;
uniform vec3      iResolution;
uniform vec4      iMouse;
uniform vec4      iDate;
uniform float     iSampleRate;
// iChannel stubs: black textures (no sampler support in this viewer)
// Declare them as vec4 constants so shaders that read iChannelX compile.
// If your shader heavily relies on textures it will look wrong, but it will compile.
const vec4 _iChannelDummy = vec4(0.0);
#define iChannel0Resolution vec3(1.0)
#define iChannel1Resolution vec3(1.0)
#define iChannel2Resolution vec3(1.0)
#define iChannel3Resolution vec3(1.0)
// -------------------------------------
"""

# Wrap the Shadertoy mainImage convention into a real GLSL main()
_SHADERTOY_MAIN_WRAPPER = """\

void main() {
    vec4 fragColor = vec4(0.0);
    vec2 fragCoord = gl_FragCoord.xy;
    mainImage(fragColor, fragCoord);
    FragColor = fragColor;
}
"""

# Shadertoy precision / version header that some shaders include but our
# compiler doesn't want duplicated
_VERSION_RE = re.compile(r"^\s*#version\s+\S+.*$", re.MULTILINE)
_PRECISION_RE = re.compile(r"^\s*precision\s+\S+\s+\S+\s*;.*$", re.MULTILINE)


def is_shadertoy_fragment(source: str) -> bool:
    """Return True if the fragment source looks like a Shadertoy shader."""
    return bool(re.search(r"\bmainImage\s*\(", source))


def adapt_shadertoy_fragment(source: str) -> str:
    """
    Preprocess a Shadertoy fragment shader so it compiles inside the
    addon's GPUShaderCreateInfo pipeline.

    Steps:
    1. Strip any #version / precision lines (the driver adds its own).
    2. Redirect iChannelN texture reads to a constant vec4(0).
       Shadertoy's texture() calls use sampler2D iChannelN; we stub them
       to return vec4(0) via macro so the shader compiles even without
       actual textures.
    3. Prepend the compatibility uniform block.
    4. Append a real main() that calls mainImage().
    """
    # Strip #version and precision directives
    source = _VERSION_RE.sub("", source)
    source = _PRECISION_RE.sub("", source)

    # Remove any existing sampler2D / samplerCube iChannel declarations
    source = re.sub(
        r"^\s*uniform\s+sampler(?:2D|Cube|2DArray)\s+iChannel\d\s*;.*$",
        "",
        source,
        flags=re.MULTILINE,
    )

    # Redirect texture(iChannelN, ...) → vec4(0.0)
    # This covers the vast majority of cases where shaders just sample a texture.
    for i in range(4):
        # texture(iChannel0, uv) → vec4(0.0)
        source = re.sub(
            r"\btexture\s*\(\s*iChannel" + str(i) + r"\s*,\s*([^)]+)\)",
            r"vec4(0.0)",
            source,
        )
        # texelFetch(iChannel0, ...) → vec4(0.0)
        source = re.sub(
            r"\btexelFetch\s*\(\s*iChannel" + str(i) + r"\s*,\s*([^)]+)\)",
            r"vec4(0.0)",
            source,
        )
        # Stub the iChannelN variable itself as a constant if the shader
        # tries to use it directly
        source = re.sub(
            r"\biChannel" + str(i) + r"\b",
            "_iChannelDummy",
            source,
        )

    source = _SHADERTOY_PREAMBLE + source + _SHADERTOY_MAIN_WRAPPER
    return source


def adapt_shadertoy_vertex(vertex_source: str) -> str:
    """
    Shadertoy shaders have no vertex stage. Return vertex_source unchanged;
    the adapter only touches the fragment side.
    """
    return vertex_source


# Shadertoy iChannel-related names to treat as builtins (never push_constant)
_SHADERTOY_UNIFORM_BLACKLIST = _SHADERTOY_BUILTIN_NAMES | {
    "iChannel0", "iChannel1", "iChannel2", "iChannel3",
    "iChannel0Resolution", "iChannel1Resolution",
    "iChannel2Resolution", "iChannel3Resolution",
}


# ------------------------------------------------------------
# Ghost material — makes objects invisible to Eevee/solid draw
# ------------------------------------------------------------

def get_or_create_ghost_material():
    """
    Return the shared invisible material, creating it if needed.
    The material is fully transparent so Eevee draws zero pixels for
    any object that uses it, while our POST_VIEW GLSL pass renders it.

    Blender 5.x API notes:
    - use_nodes is deprecated; node tree exists automatically on new materials
    - shadow_method was removed in Blender 4.x
    - blend_method was removed in Blender 4.2+ (Eevee Next); alpha is now
      controlled via the node tree's surface alpha output
    """
    mat = bpy.data.materials.get(_GHOST_MAT_NAME)
    if mat is None:
        mat = bpy.data.materials.new(name=_GHOST_MAT_NAME)

    # Enable node-based shading (works across versions)
    if not mat.node_tree:
        mat.use_nodes = True

    # Blender 4.x: blend_method controls alpha mode
    if hasattr(mat, 'blend_method'):
        mat.blend_method = 'BLEND'
    # Blender 5.x / Eevee Next: surface_render_method replaces blend_method
    if hasattr(mat, 'surface_render_method'):
        mat.surface_render_method = 'BLENDED'

    # Node tree: Transparent BSDF → Material Output
    # Eevee (both legacy and Next) renders this as fully transparent.
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    nodes.clear()
    out  = nodes.new('ShaderNodeOutputMaterial')
    bsdf = nodes.new('ShaderNodeBsdfTransparent')
    links.new(bsdf.outputs['BSDF'], out.inputs['Surface'])

    # Solid-mode viewport color is driven by diffuse_color alpha.
    mat.diffuse_color = (0.0, 0.0, 0.0, 0.0)

    return mat


def assign_ghost_material(obj):
    """
    Replace obj's material slots with the ghost material so Eevee/solid
    renders nothing.  Saves original slots in obj['_ss_orig_mats'].
    """
    ghost = get_or_create_ghost_material()
    # Already ghosted?
    if obj.get("_ss_ghosted"):
        return
    # Save original material pointers (None = empty slot)
    orig = [slot.material for slot in obj.material_slots]
    obj["_ss_orig_mats"] = [m.name if m else "" for m in orig]
    obj["_ss_ghosted"] = True
    # Ensure at least one slot exists, then assign ghost to all slots.
    # Use the data API (obj.data.materials) to avoid needing a context override.
    if len(obj.material_slots) == 0:
        obj.data.materials.append(ghost)
    else:
        for slot in obj.material_slots:
            slot.material = ghost


def restore_ghost_material(obj):
    """
    Undo assign_ghost_material: put original materials back.
    """
    if not obj.get("_ss_ghosted"):
        return
    orig_names = obj.get("_ss_orig_mats", [])
    for i, slot in enumerate(obj.material_slots):
        if i < len(orig_names):
            name = orig_names[i]
            slot.material = bpy.data.materials.get(name) if name else None
        else:
            slot.material = None
    del obj["_ss_ghosted"]
    if "_ss_orig_mats" in obj:
        del obj["_ss_orig_mats"]


def sync_ghost_materials(scene, root_folder):
    """
    Walk all mesh objects:
    - Objects WITH a valid GLSL shader → assign ghost material
    - Objects WITHOUT one → restore original material if ghosted
    Called on Refresh and whenever simple_shader_name changes.
    """
    if not root_folder or not os.path.isdir(root_folder):
        # No valid root: restore everything
        for obj in scene.objects:
            if obj.type == 'MESH' and obj.get("_ss_ghosted"):
                restore_ghost_material(obj)
        return

    for obj in scene.objects:
        if obj.type != 'MESH':
            continue
        shader_name = get_effective_shader_name(obj)
        has_shader = False
        if shader_name:
            sf = os.path.normpath(os.path.join(root_folder, shader_name))
            has_shader = get_object_shader(sf) is not None

        if has_shader and not obj.get("_ss_ghosted"):
            assign_ghost_material(obj)
        elif not has_shader and obj.get("_ss_ghosted"):
            restore_ghost_material(obj)


# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

def camera_poll(self, obj):
    return obj is not None and obj.type == 'CAMERA'


def any_object_poll(self, obj):
    return obj is not None


def tag_redraw_view3d():
    wm = bpy.context.window_manager
    for window in wm.windows:
        for area in window.screen.areas:
            if area.type == 'VIEW_3D':
                area.tag_redraw()


def load_text_file(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def safe_set_uniform(shader, name, value):
    """
    Try to set a uniform. Handles float, int, vec2/3/4, mat3, mat4.
    Returns True on success, False if the uniform doesn't exist in the shader.
    """
    try:
        if isinstance(value, int):
            try:
                shader.uniform_int(name, value)
            except Exception:
                shader.uniform_float(name, float(value))
            return True
        if isinstance(value, (tuple, list)):
            shader.uniform_float(name, value)
            return True
        shader.uniform_float(name, value)
        return True
    except Exception:
        return False


def get_effective_shader_name(obj):
    if obj is None:
        return ""
    name = getattr(obj, "simple_shader_name", "").strip()
    if name:
        return name
    return ""   # Do NOT fall back to obj.name — that would ghost every object


def shader_name_update(self, context):
    """Called when simple_shader_name changes on an object."""
    scene = context.scene
    root_folder = bpy.path.abspath(scene.simple_shader_root_folder)

    sync_ghost_materials(scene, root_folder)
    sync_object_uniforms_from_fragment(scene, self, root_folder)
    tag_redraw_view3d()


# ------------------------------------------------------------
# GLSL uniform parser
# ------------------------------------------------------------

_GLSL_TYPE_MAP = {
    "float":  "FLOAT",
    "int":    "INT",
    "uint":   "UINT",
    "bool":   "BOOL",
    "vec2":   "VEC2",
    "vec3":   "VEC3",
    "vec4":   "VEC4",
    "ivec2":  "IVEC2",
    "ivec3":  "IVEC3",
    "ivec4":  "IVEC4",
    "uvec2":  "UVEC2",
    "uvec3":  "UVEC3",
    "uvec4":  "UVEC4",
    "mat3":   "MAT3",
    "mat4":   "MAT4",
}

_UNIFORM_RE = re.compile(
    r"^\s*uniform\s+(" + "|".join(re.escape(k) for k in _GLSL_TYPE_MAP) + r")\s+(\w+)\s*;",
    re.MULTILINE,
)


def parse_custom_uniforms(vertex_source, fragment_source):
    BUILTIN_NAMES = {
        "ModelViewProjectionMatrix",
        "u_time", "u_frame",
        "u_camera_position", "u_camera_rotation", "u_camera_matrix",
    } | _SHADERTOY_BUILTIN_NAMES
    seen = {}
    for source in (vertex_source, fragment_source):
        for m in _UNIFORM_RE.finditer(source):
            glsl_type, uname = m.group(1), m.group(2)
            if uname not in BUILTIN_NAMES:
                seen[uname] = glsl_type
    return [(glsl_type, name) for name, glsl_type in seen.items()]


# ------------------------------------------------------------
# Shader builders
# ------------------------------------------------------------

def build_bg_shader():
    info = gpu.types.GPUShaderCreateInfo()
    info.push_constant("VEC4", "u_color")
    info.vertex_in(0, "VEC2", "pos")
    info.fragment_out(0, "VEC4", "FragColor")
    info.vertex_source("""
    void main() { gl_Position = vec4(pos, 0.0, 1.0); }
    """)
    info.fragment_source("""
    void main() { FragColor = u_color; }
    """)
    return gpu.shader.create_from_info(info)


def strip_uniform_declarations(source, names_to_strip):
    if not names_to_strip:
        return source
    pattern = re.compile(
        r"^\s*uniform\s+\S+\s+(" + "|".join(re.escape(n) for n in names_to_strip) + r")\s*;\s*\n?",
        re.MULTILINE,
    )
    return pattern.sub("", source)


def build_object_shader(vertex_source, fragment_source, is_shadertoy=False):
    """
    Build a GPUShader from vertex + fragment source.
    If is_shadertoy is True, the fragment has already been preprocessed by
    adapt_shadertoy_fragment() and needs the Shadertoy push_constants added.
    """
    info = gpu.types.GPUShaderCreateInfo()
    info.push_constant("MAT4", "ModelViewProjectionMatrix")
    info.push_constant("FLOAT", "u_time")
    info.push_constant("FLOAT", "u_frame")
    info.push_constant("VEC3",  "u_camera_position")
    info.push_constant("MAT3",  "u_camera_rotation")
    info.push_constant("MAT4",  "u_camera_matrix")

    if is_shadertoy:
        # Shadertoy built-ins become push_constants
        info.push_constant("FLOAT", "iTime")
        info.push_constant("FLOAT", "iTimeDelta")
        info.push_constant("INT",   "iFrame")
        info.push_constant("FLOAT", "iFrameRate")
        info.push_constant("VEC3",  "iResolution")
        info.push_constant("VEC4",  "iMouse")
        info.push_constant("VEC4",  "iDate")
        info.push_constant("FLOAT", "iSampleRate")

    custom = parse_custom_uniforms(vertex_source, fragment_source)
    custom_names = set()
    for glsl_type, uname in custom:
        pc_type = _GLSL_TYPE_MAP[glsl_type]
        info.push_constant(pc_type, uname)
        custom_names.add(uname)

    info.vertex_in(0, "VEC3", "pos")
    info.fragment_out(0, "VEC4", "FragColor")

    # Strip uniform declarations that are now push_constants
    all_stripped = custom_names
    if is_shadertoy:
        all_stripped = custom_names | _SHADERTOY_BUILTIN_NAMES

    vertex_source   = strip_uniform_declarations(vertex_source,   all_stripped)
    fragment_source = strip_uniform_declarations(fragment_source, all_stripped)

    info.vertex_source(vertex_source)
    info.fragment_source(fragment_source)
    return gpu.shader.create_from_info(info)


def compile_shader_folder(shader_folder):
    vertex_path   = os.path.join(shader_folder, "vertex.glsl")
    fragment_path = os.path.join(shader_folder, "fragment.glsl")
    if not os.path.isfile(vertex_path):
        return None, f"Missing file: {vertex_path}", False
    if not os.path.isfile(fragment_path):
        return None, f"Missing file: {fragment_path}", False
    try:
        raw_vertex   = load_text_file(vertex_path)
        raw_fragment = load_text_file(fragment_path)

        shadertoy = is_shadertoy_fragment(raw_fragment)
        if shadertoy:
            fragment = adapt_shadertoy_fragment(raw_fragment)
            vertex   = adapt_shadertoy_vertex(raw_vertex)
        else:
            fragment = raw_fragment
            vertex   = raw_vertex

        shader = build_object_shader(vertex, fragment, is_shadertoy=shadertoy)
        return shader, "", shadertoy
    except Exception as e:
        return None, str(e), False


def rebuild_shader_cache(root_folder):
    _shader_cache.clear()
    if not root_folder or not os.path.isdir(root_folder):
        return
    for entry in sorted(os.listdir(root_folder)):
        folder = os.path.join(root_folder, entry)
        if not os.path.isdir(folder):
            continue
        shader, error, shadertoy = compile_shader_folder(folder)
        _shader_cache[os.path.normpath(folder)] = {
            "shader": shader,
            "error": error,
            "shadertoy": shadertoy,
        }


def get_object_shader(shader_folder):
    shader_folder = os.path.normpath(shader_folder)
    cached = _shader_cache.get(shader_folder)
    if cached is not None:
        return cached.get("shader")
    shader, error, shadertoy = compile_shader_folder(shader_folder)
    _shader_cache[shader_folder] = {"shader": shader, "error": error, "shadertoy": shadertoy}
    return shader


def is_shadertoy_shader_folder(shader_folder):
    shader_folder = os.path.normpath(shader_folder)
    cached = _shader_cache.get(shader_folder)
    if cached is not None:
        return cached.get("shadertoy", False)
    # Not cached yet — peek at the file directly
    frag_path = os.path.join(shader_folder, "fragment.glsl")
    if os.path.isfile(frag_path):
        try:
            return is_shadertoy_fragment(load_text_file(frag_path))
        except Exception:
            pass
    return False


def find_last_shader_template_object(scene, shader_name, exclude_obj=None):
    """
    Return the most recently encountered mesh object in the scene that uses
    the same shader folder. This acts like the 'last object created' template.
    """
    template = None
    for obj in scene.objects:
        if obj is exclude_obj:
            continue
        if obj.type != 'MESH':
            continue
        if get_effective_shader_name(obj) == shader_name:
            template = obj
    return template


def copy_uniform_item_value(dst, src):
    """
    Copy the stored value from src into dst, assuming the same data_type.
    """
    if src is None:
        return

    try:
        if dst.data_type == 'FLOAT':
            dst.f0 = src.f0
        elif dst.data_type == 'VEC2':
            dst.f0, dst.f1 = src.f0, src.f1
        elif dst.data_type == 'VEC3':
            dst.f0, dst.f1, dst.f2 = src.f0, src.f1, src.f2
        elif dst.data_type == 'VEC4':
            dst.f0, dst.f1, dst.f2, dst.f3 = src.f0, src.f1, src.f2, src.f3
        elif dst.data_type == 'INT':
            dst.i0 = src.i0
        elif dst.data_type in _OBJ_LINK_TYPES:
            dst.obj_target = src.obj_target
    except Exception:
        pass


def sync_object_uniforms_from_fragment(scene, obj, root_folder):
    """
    When an object gets a shader folder name, read fragment.glsl and
    auto-create any missing object uniforms from its custom uniforms.

    New uniforms inherit values from the most recent other object in the scene
    that uses the same shader folder.
    """
    if obj is None or obj.type != 'MESH':
        return

    shader_name = get_effective_shader_name(obj)
    if not shader_name:
        return

    if not root_folder or not os.path.isdir(root_folder):
        return

    frag_path = os.path.normpath(os.path.join(root_folder, shader_name, "fragment.glsl"))
    if not os.path.isfile(frag_path):
        return

    try:
        fragment_source = load_text_file(frag_path)
    except Exception:
        return

    custom_uniforms = parse_custom_uniforms("", fragment_source)

    # Find a template object that already uses this shader folder.
    template_obj = find_last_shader_template_object(scene, shader_name, exclude_obj=obj)
    template_items = {}
    if template_obj is not None:
        for item in template_obj.simple_shader_uniforms:
            name = item.name.strip()
            if name:
                template_items[name] = item

    existing = {}
    for item in obj.simple_shader_uniforms:
        name = item.name.strip()
        if name:
            existing[name] = item

    for glsl_type, uname in custom_uniforms:
        item = existing.get(uname)
        if item is None:
            item = obj.simple_shader_uniforms.add()
            item.name = uname
            item.data_type = _GLSL_TYPE_MAP.get(glsl_type, 'FLOAT')

            # Copy the value from the matching uniform on the template object.
            template_item = template_items.get(uname)
            copy_uniform_item_value(item, template_item)
        else:
            # Keep the type synced to the shader definition.
            item.data_type = _GLSL_TYPE_MAP.get(glsl_type, 'FLOAT')


def get_scene_time(scene):
    fps = scene.render.fps / max(scene.render.fps_base, 0.0001)
    return float(scene.frame_current) / max(fps, 0.0001)


def get_idate():
    """Return Shadertoy iDate: vec4(year, month, day, seconds_since_midnight)."""
    now = datetime.datetime.now()
    seconds = now.hour * 3600 + now.minute * 60 + now.second + now.microsecond / 1e6
    return (float(now.year), float(now.month - 1), float(now.day), seconds)


_OBJ_LINK_TYPES = {'OBJ_POSITION', 'OBJ_ROTATION', 'OBJ_MATRIX', 'OBJ_SCALE'}


def uniform_value_from_item(item, depsgraph=None):
    dt = item.data_type
    if dt == 'FLOAT':  return item.f0
    if dt == 'VEC2':   return (item.f0, item.f1)
    if dt == 'VEC3':   return (item.f0, item.f1, item.f2)
    if dt == 'VEC4':   return (item.f0, item.f1, item.f2, item.f3)
    if dt == 'INT':    return int(item.i0)
    if dt in _OBJ_LINK_TYPES:
        target = item.obj_target
        if target is None:
            return None
        if depsgraph is not None:
            try:
                target = target.evaluated_get(depsgraph)
            except Exception:
                pass
        mat = target.matrix_world.copy()
        if dt == 'OBJ_POSITION': return mat.translation[:]
        if dt == 'OBJ_ROTATION': return mat.to_3x3()
        if dt == 'OBJ_MATRIX':   return mat
        if dt == 'OBJ_SCALE':
            s = mat.to_scale()
            return (s.x, s.y, s.z)
    return None


def draw_error_box(layout, title, error_text):
    box = layout.box()
    box.label(text=title)
    lines = error_text.splitlines() if error_text else ["Unknown error"]
    for line in lines[:8]:
        box.label(text=line[:140])
    if len(lines) > 8:
        box.label(text="...")


def draw_uniform_item(layout, item, show_folder_name=False,
                      remove_operator_id=None, remove_index=None):
    box = layout.box()
    header = box.row(align=True)
    header.prop(item, "name", text="Name")
    header.prop(item, "data_type", text="Type")
    if remove_operator_id is not None:
        op = header.operator(remove_operator_id, text="", icon="REMOVE")
        op.index = remove_index
    if show_folder_name:
        box.prop(item, "folder_name", text="Folder")
    dt = item.data_type
    if dt == 'FLOAT':
        box.prop(item, "f0", text="Value")
    elif dt == 'VEC2':
        row = box.row(align=True)
        row.prop(item, "f0", text="X"); row.prop(item, "f1", text="Y")
    elif dt == 'VEC3':
        row = box.row(align=True)
        row.prop(item, "f0", text="X"); row.prop(item, "f1", text="Y"); row.prop(item, "f2", text="Z")
    elif dt == 'VEC4':
        row = box.row(align=True)
        row.prop(item, "f0", text="X"); row.prop(item, "f1", text="Y")
        row.prop(item, "f2", text="Z"); row.prop(item, "f3", text="W")
    elif dt == 'INT':
        box.prop(item, "i0", text="Value")
    elif dt in _OBJ_LINK_TYPES:
        box.prop(item, "obj_target", text="Object")
        glsl_hint = {
            'OBJ_POSITION': "→ vec3  (world position)",
            'OBJ_ROTATION': "→ mat3  (world rotation)",
            'OBJ_MATRIX':   "→ mat4  (world matrix)",
            'OBJ_SCALE':    "→ vec3  (world scale)",
        }
        hint = glsl_hint.get(dt, "")
        if hint:
            row = box.row(); row.enabled = False
            row.label(text=hint, icon='INFO')


# ------------------------------------------------------------
# Property Groups
# ------------------------------------------------------------

class SIMPLESHADER_PG_UniformItem(bpy.types.PropertyGroup):
    folder_name: StringProperty(name="Folder", default="")
    name:        StringProperty(name="Name",   default="u_custom")
    data_type: EnumProperty(
        name="Type",
        items=[
            ('FLOAT',        "Float",           "Single float value"),
            ('VEC2',         "Vec2",            "Two-component float vector"),
            ('VEC3',         "Vec3",            "Three-component float vector"),
            ('VEC4',         "Vec4",            "Four-component float vector"),
            ('INT',          "Int",             "Integer value"),
            ('OBJ_POSITION', "Object Position", "World-space position → vec3"),
            ('OBJ_ROTATION', "Object Rotation", "World-space rotation matrix → mat3"),
            ('OBJ_MATRIX',   "Object Matrix",   "Full world matrix → mat4"),
            ('OBJ_SCALE',    "Object Scale",    "World-space scale → vec3"),
        ],
        default='FLOAT',
    )
    f0: FloatProperty(name="X", default=0.0)
    f1: FloatProperty(name="Y", default=0.0)
    f2: FloatProperty(name="Z", default=0.0)
    f3: FloatProperty(name="W", default=0.0)
    i0: IntProperty(name="Value", default=0)
    obj_target: PointerProperty(
        name="Object", type=bpy.types.Object, poll=any_object_poll,
        description="Scene object whose transform will be passed as the uniform value",
    )


# ------------------------------------------------------------
# Operators
# ------------------------------------------------------------

class SIMPLESHADER_OT_refresh(bpy.types.Operator):
    bl_idname  = "simpleshader.refresh"
    bl_label   = "Refresh Shaders"
    bl_description = "Re-scan the root folder, compile all shader folders, sync materials"

    def execute(self, context):
        os.system("cls")
        scene = context.scene
        root_folder = bpy.path.abspath(scene.simple_shader_root_folder)
        rebuild_shader_cache(root_folder)
        sync_ghost_materials(scene, root_folder)
        tag_redraw_view3d()
        error_count = sum(1 for v in _shader_cache.values() if v.get("error"))
        shadertoy_count = sum(1 for v in _shader_cache.values() if v.get("shadertoy"))
        self.report(
            {'INFO'},
            f"Refreshed. {error_count} compile error(s). {shadertoy_count} Shadertoy shader(s) detected.",
        )
        return {'FINISHED'}


class SIMPLESHADER_OT_folder_uniform_add(bpy.types.Operator):
    bl_idname  = "simpleshader.folder_uniform_add"
    bl_label   = "Add Folder Uniform"
    bl_description = "Add a custom uniform for all objects using this shader folder"

    def execute(self, context):
        scene = context.scene
        obj   = context.object
        if obj is None or obj.type != 'MESH':
            return {'CANCELLED'}
        folder_name = get_effective_shader_name(obj)
        if not folder_name:
            return {'CANCELLED'}
        item = scene.simple_shader_folder_uniforms.add()
        item.folder_name = folder_name
        item.name = "u_custom"
        item.data_type = 'FLOAT'
        return {'FINISHED'}


class SIMPLESHADER_OT_folder_uniform_remove(bpy.types.Operator):
    bl_idname = "simpleshader.folder_uniform_remove"
    bl_label  = "Remove Folder Uniform"
    index: IntProperty()

    def execute(self, context):
        scene = context.scene
        if self.index < 0 or self.index >= len(scene.simple_shader_folder_uniforms):
            return {'CANCELLED'}
        scene.simple_shader_folder_uniforms.remove(self.index)
        return {'FINISHED'}


class SIMPLESHADER_OT_object_uniform_add(bpy.types.Operator):
    bl_idname  = "simpleshader.object_uniform_add"
    bl_label   = "Add Object Uniform"
    bl_description = "Add a custom uniform that applies only to the active object"

    def execute(self, context):
        obj = context.object
        if obj is None or obj.type != 'MESH':
            return {'CANCELLED'}
        item = obj.simple_shader_uniforms.add()
        item.name = "u_custom"
        item.data_type = 'FLOAT'
        return {'FINISHED'}


class SIMPLESHADER_OT_object_uniform_remove(bpy.types.Operator):
    bl_idname = "simpleshader.object_uniform_remove"
    bl_label  = "Remove Object Uniform"
    index: IntProperty()

    def execute(self, context):
        obj = context.object
        if obj is None or obj.type != 'MESH':
            return {'CANCELLED'}
        if self.index < 0 or self.index >= len(obj.simple_shader_uniforms):
            return {'CANCELLED'}
        obj.simple_shader_uniforms.remove(self.index)
        return {'FINISHED'}


# ------------------------------------------------------------
# UI
# ------------------------------------------------------------

class VIEW3D_PT_simple_shader(bpy.types.Panel):
    bl_label      = "Simple Shader"
    bl_idname     = "VIEW3D_PT_simple_shader"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category   = "Shader"

    def draw(self, context):
        layout = self.layout
        scene  = context.scene
        obj    = context.object

        layout.prop(scene, "simple_shader_enabled")
        layout.prop(scene, "simple_shader_root_folder")
        layout.operator("simpleshader.refresh", icon="FILE_REFRESH")

        layout.separator()
        layout.prop(scene, "simple_shader_camera")
        layout.prop(scene, "simple_shader_bg_color")

        if obj and obj.type == 'MESH':
            folder_name = get_effective_shader_name(obj)

            layout.separator()
            box = layout.box()
            box.label(text=f"Object: {obj.name}")
            box.prop(obj, "simple_shader_name", text="Shader Folder")

            # Ghost material status indicator
            if obj.get("_ss_ghosted"):
                row = box.row()
                row.enabled = False
                row.label(text="Eevee draw suppressed (ghost mat active)", icon='HIDE_ON')
            elif folder_name:
                row = box.row()
                row.enabled = False
                row.label(text="Shader set but not yet refreshed", icon='ERROR')

            # Shadertoy mode indicator
            if folder_name:
                root_folder = bpy.path.abspath(scene.simple_shader_root_folder)
                sf = os.path.normpath(os.path.join(root_folder, folder_name))
                cached = _shader_cache.get(sf)
                if cached and cached.get("shadertoy"):
                    st_row = box.row()
                    st_row.enabled = False
                    st_row.label(text="Shadertoy mode: iTime/iResolution/etc. active", icon='SHADERFX')

            box.label(text="⚠ Uniforms must match 'uniform T name;' in your GLSL.", icon='INFO')

            box.row(align=True).operator("simpleshader.object_uniform_add",
                                         icon="ADD", text="Add Object Uniform")
            for idx, item in enumerate(obj.simple_shader_uniforms):
                draw_uniform_item(box, item,
                                  remove_operator_id="simpleshader.object_uniform_remove",
                                  remove_index=idx)

            layout.separator()
            box = layout.box()
            box.label(text=f"Folder Defaults: {folder_name or '(none)'}")
            box.row(align=True).operator("simpleshader.folder_uniform_add",
                                          icon="ADD", text="Add Folder Uniform")
            shown_any = False
            for idx, item in enumerate(scene.simple_shader_folder_uniforms):
                if item.folder_name.strip() != folder_name:
                    continue
                shown_any = True
                draw_uniform_item(box, item, show_folder_name=True,
                                  remove_operator_id="simpleshader.folder_uniform_remove",
                                  remove_index=idx)
            if not shown_any:
                box.label(text="No folder uniforms yet.")

        layout.separator()
        box = layout.box()
        box.label(text="Compile Errors")
        root_folder = bpy.path.abspath(scene.simple_shader_root_folder)
        if not root_folder or not os.path.isdir(root_folder):
            box.label(text="Set a valid root folder and press Refresh.")
            return
        shown = False
        for folder, data in sorted(_shader_cache.items()):
            if os.path.normpath(folder).startswith(os.path.normpath(root_folder)):
                error = data.get("error", "")
                if error:
                    shown = True
                    draw_error_box(box, os.path.basename(folder), error)
        if not shown:
            box.label(text="No compile errors cached.")


# ------------------------------------------------------------
# Drawing
# ------------------------------------------------------------

def _iter_glsl_objects(scene, root_folder):
    """
    Yield (obj, shader_name, shader_folder) for every mesh that has a
    valid compiled GLSL shader.  Uses original (non-evaluated) objects.
    """
    for obj in scene.objects:
        if obj.type != 'MESH':
            continue
        shader_name = get_effective_shader_name(obj)
        if not shader_name:
            continue
        shader_folder = os.path.normpath(os.path.join(root_folder, shader_name))
        if get_object_shader(shader_folder) is not None:
            yield obj, shader_name, shader_folder


def _get_viewport_resolution(context):
    """Return (width, height) of the active 3D viewport region."""
    region = context.region
    if region is not None:
        return float(region.width), float(region.height)
    # Fallback: scan for any VIEW_3D region
    for window in context.window_manager.windows:
        for area in window.screen.areas:
            if area.type == 'VIEW_3D':
                for region in area.regions:
                    if region.type == 'WINDOW':
                        return float(region.width), float(region.height)
    return 1920.0, 1080.0


def draw_callback_view():
    """
    POST_VIEW — the scene has been drawn (ghost objects rendered as nothing),
    depth buffer is intact.  We now draw GLSL objects with proper depth
    testing so they integrate naturally with Eevee / solid geometry.
    """
    context = bpy.context
    scene = context.scene
    if not scene.simple_shader_enabled:
        return

    region_data = context.region_data
    if region_data is None:
        return

    root_folder = bpy.path.abspath(scene.simple_shader_root_folder)
    if not root_folder or not os.path.isdir(root_folder):
        return

    cam = scene.simple_shader_camera
    cam_ok     = cam is not None and cam.type == 'CAMERA'
    cam_matrix = cam.matrix_world.copy() if cam_ok else None
    cam_position = cam_matrix.translation if cam_ok else None
    cam_rotation = cam_matrix.to_3x3()   if cam_ok else None

    time_sec  = get_scene_time(scene)
    frame_num = float(scene.frame_current)
    depsgraph = context.evaluated_depsgraph_get()

    # Shadertoy time values
    fps = scene.render.fps / max(scene.render.fps_base, 0.0001)
    i_time_delta = 1.0 / max(fps, 0.0001)
    i_frame_rate = fps
    i_frame_int  = scene.frame_current
    i_date       = get_idate()
    vp_w, vp_h   = _get_viewport_resolution(context)
    i_resolution = (vp_w, vp_h, 1.0)

    gpu.state.blend_set('ALPHA')
    gpu.state.depth_test_set('LESS_EQUAL')
    gpu.state.depth_mask_set(True)
    gpu.state.face_culling_set('BACK')

    for obj, shader_name, shader_folder in _iter_glsl_objects(scene, root_folder):
        shader = get_object_shader(shader_folder)
        if shader is None:
            continue

        shadertoy = is_shadertoy_shader_folder(shader_folder)

        obj_eval = obj.evaluated_get(depsgraph)
        mesh = obj_eval.to_mesh()
        try:
            mesh.calc_loop_triangles()
            positions = [v.co[:] for v in mesh.vertices]
            indices   = [tuple(tri.vertices) for tri in mesh.loop_triangles]

            batch = batch_for_shader(shader, "TRIS",
                                     {"pos": positions}, indices=indices)

            mvp = region_data.perspective_matrix @ obj.matrix_world
            shader.bind()
            safe_set_uniform(shader, "ModelViewProjectionMatrix", mvp)
            safe_set_uniform(shader, "u_time",  time_sec)
            safe_set_uniform(shader, "u_frame", frame_num)

            if cam_ok:
                safe_set_uniform(shader, "u_camera_position", cam_position)
                safe_set_uniform(shader, "u_camera_rotation", cam_rotation)
                safe_set_uniform(shader, "u_camera_matrix",   cam_matrix)

            # Shadertoy built-in uniforms
            if shadertoy:
                safe_set_uniform(shader, "iTime",      time_sec)
                safe_set_uniform(shader, "iTimeDelta", i_time_delta)
                try:
                    shader.uniform_int("iFrame", i_frame_int)
                except Exception:
                    safe_set_uniform(shader, "iFrame", float(i_frame_int))
                safe_set_uniform(shader, "iFrameRate",  i_frame_rate)
                safe_set_uniform(shader, "iResolution", i_resolution)
                safe_set_uniform(shader, "iMouse",      (0.0, 0.0, 0.0, 0.0))
                safe_set_uniform(shader, "iDate",       i_date)
                safe_set_uniform(shader, "iSampleRate", 44100.0)

            for item in scene.simple_shader_folder_uniforms:
                if item.folder_name.strip() != shader_name:
                    continue
                value = uniform_value_from_item(item, depsgraph)
                if value is not None:
                    safe_set_uniform(shader, item.name.strip(), value)

            for item in obj.simple_shader_uniforms:
                value = uniform_value_from_item(item, depsgraph)
                if value is not None:
                    safe_set_uniform(shader, item.name.strip(), value)

            batch.draw(shader)
        finally:
            obj_eval.to_mesh_clear()

    gpu.state.depth_mask_set(False)
    gpu.state.depth_test_set('NONE')
    gpu.state.blend_set('NONE')
    gpu.state.face_culling_set('NONE')


def draw_callback_pixel():
    """
    POST_PIXEL — screen-space background quad only.  No depth involvement.
    """
    global _bg_shader

    scene = bpy.context.scene
    if not scene.simple_shader_enabled:
        return

    if _bg_shader is None:
        _bg_shader = build_bg_shader()

    bg_batch = batch_for_shader(
        _bg_shader, "TRIS",
        {"pos": [(-1, -1), (1, -1), (1, 1), (-1, 1)]},
        indices=[(0, 1, 2), (0, 2, 3)],
    )

    gpu.state.blend_set('ALPHA')
    gpu.state.depth_test_set('NONE')
    gpu.state.depth_mask_set(False)
    gpu.state.face_culling_set('NONE')

    _bg_shader.bind()
    _bg_shader.uniform_float("u_color", scene.simple_shader_bg_color)
    bg_batch.draw(_bg_shader)

    gpu.state.blend_set('NONE')


# ------------------------------------------------------------
# Register
# ------------------------------------------------------------

classes = (
    SIMPLESHADER_PG_UniformItem,
    SIMPLESHADER_OT_refresh,
    SIMPLESHADER_OT_folder_uniform_add,
    SIMPLESHADER_OT_folder_uniform_remove,
    SIMPLESHADER_OT_object_uniform_add,
    SIMPLESHADER_OT_object_uniform_remove,
    VIEW3D_PT_simple_shader,
)


def register():
    for cls in classes:
        bpy.utils.register_class(cls)

    bpy.types.Scene.simple_shader_enabled = BoolProperty(
        name="Enabled", default=True)

    bpy.types.Scene.simple_shader_root_folder = StringProperty(
        name="Root Folder", subtype='DIR_PATH', default="")

    bpy.types.Scene.simple_shader_camera = PointerProperty(
        name="Camera", type=bpy.types.Object, poll=camera_poll)

    bpy.types.Scene.simple_shader_bg_color = FloatVectorProperty(
        name="Background Color", subtype="COLOR",
        size=4, min=0.0, max=1.0,
        default=(0.08, 0.08, 0.10, 0.0))

    bpy.types.Scene.simple_shader_folder_uniforms = CollectionProperty(
        type=SIMPLESHADER_PG_UniformItem)

    bpy.types.Object.simple_shader_name = StringProperty(
        name="Shader Folder Name", default="",
        update=shader_name_update)

    bpy.types.Object.simple_shader_uniforms = CollectionProperty(
        type=SIMPLESHADER_PG_UniformItem)

    global _draw_handle_view, _draw_handle_pixel
    _draw_handle_view = bpy.types.SpaceView3D.draw_handler_add(
        draw_callback_view, (), "WINDOW", "POST_VIEW")
    _draw_handle_pixel = bpy.types.SpaceView3D.draw_handler_add(
        draw_callback_pixel, (), "WINDOW", "POST_PIXEL")


def unregister():
    global _draw_handle_view, _draw_handle_pixel, _bg_shader

    if _draw_handle_view is not None:
        bpy.types.SpaceView3D.draw_handler_remove(_draw_handle_view, "WINDOW")
        _draw_handle_view = None
    if _draw_handle_pixel is not None:
        bpy.types.SpaceView3D.draw_handler_remove(_draw_handle_pixel, "WINDOW")
        _draw_handle_pixel = None

    # Restore all ghosted objects before unregistering
    try:
        for scene in bpy.data.scenes:
            for obj in scene.objects:
                if obj.type == 'MESH' and obj.get("_ss_ghosted"):
                    restore_ghost_material(obj)
        # Remove the ghost material itself if nothing else uses it
        ghost = bpy.data.materials.get(_GHOST_MAT_NAME)
        if ghost is not None and ghost.users == 0:
            bpy.data.materials.remove(ghost)
    except Exception:
        pass

    _shader_cache.clear()
    _bg_shader = None

    del bpy.types.Scene.simple_shader_enabled
    del bpy.types.Scene.simple_shader_root_folder
    del bpy.types.Scene.simple_shader_camera
    del bpy.types.Scene.simple_shader_bg_color
    del bpy.types.Scene.simple_shader_folder_uniforms
    del bpy.types.Object.simple_shader_name
    del bpy.types.Object.simple_shader_uniforms

    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()