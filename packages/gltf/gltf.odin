package gltf

import "core:encoding/json"
import "core:image"
import _ "core:image/jpeg"
import _ "core:image/png"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import zmath "zelda_engine:math"

GLB_MAGIC :: u32(0x46546c67)
GLB_JSON_CHUNK :: u32(0x4e4f534a)
GLB_BIN_CHUNK :: u32(0x004e4942)

Vec3 :: struct { x, y, z: f32 }
Vec4 :: struct { x, y, z, w: f32 }
Vec2 :: zmath.Vec2
Glb_Joints :: [4]u16
Glb_Texture_Data :: struct {pixels:[dynamic]u8,width,height:int}
Glb_Primitive_Range :: struct {first,count,texture:int, base_color:[4]f32}
Glb_Mesh :: struct {
	vertices: [dynamic]Vec3,
	texcoords: [dynamic]Vec2,
	indices: [dynamic]u32,
	primitives: [dynamic]Glb_Primitive_Range,
	// Parallel primitive metadata. alpha_mode follows glTF: 0 OPAQUE, 1 MASK, 2 BLEND.
	alpha_modes:[dynamic]int,
	alpha_cutoffs:[dynamic]f32,
	material_names: [dynamic]string,
	normal_textures, roughness_textures: [dynamic]int,
	metallic_factors, roughness_factors, normal_scales: [dynamic]f32,
	textures: [dynamic]Glb_Texture_Data,
	animations: [dynamic]string,
	joints: [dynamic]Glb_Joints,
	weights: [dynamic]Vec4,
	nodes: [dynamic]Glb_Runtime_Node,
	skin: Glb_Skin,
	clips: [dynamic]Glb_Animation_Clip,
	min, max: Vec3,
	ready: bool,
}
GLB_MAX_JOINTS :: 64

Glb_TRS :: struct {translation:Vec3,rotation:Vec4,scale:Vec3}
Glb_Runtime_Node :: struct {parent:int,bind:Glb_TRS}
Glb_Skin :: struct {joints:[dynamic]int,inverse_bind:[dynamic]Glb_Mat4,mesh_node:int}
Glb_Interpolation :: enum {Linear,Step}
Glb_Animation_Path :: enum {Translation,Rotation,Scale}
Glb_Animation_Channel :: struct {node:int,path:Glb_Animation_Path,interpolation:Glb_Interpolation,times:[dynamic]f32,values:[dynamic]Vec4}
Glb_Animation_Clip :: struct {name:string,duration:f32,channels:[dynamic]Glb_Animation_Channel}

Glb_Buffer_View :: struct {
	buffer: int,
	byte_offset: int `json:"byteOffset"`,
	byte_length: int `json:"byteLength"`,
	byte_stride: int `json:"byteStride"`,
}
Glb_Accessor :: struct {
	buffer_view: int `json:"bufferView"`,
	byte_offset: int `json:"byteOffset"`,
	component_type: int `json:"componentType"`,
	count: int,
	kind: string `json:"type"`,
}
Glb_Attributes :: struct { position: int `json:"POSITION"`, texcoord_0: int `json:"TEXCOORD_0"`, joints_0:int `json:"JOINTS_0"`,weights_0:int `json:"WEIGHTS_0"` }
Glb_Primitive :: struct { attributes: Glb_Attributes, indices, material, mode: int }
Glb_Source_Mesh :: struct { primitives: []Glb_Primitive }
Glb_Animation_Sampler :: struct {input,output:int,interpolation:string}
Glb_Animation_Target :: struct {node:int,path:string}
Glb_Animation_Channel_Source :: struct {sampler:int,target:Glb_Animation_Target}
Glb_Source_Animation :: struct {name: string,samplers:[]Glb_Animation_Sampler,channels:[]Glb_Animation_Channel_Source}
Glb_Skin_Source :: struct {inverse_bind_matrices:int `json:"inverseBindMatrices"`,joints:[]int,skeleton:int}
Glb_Scene_Source :: struct {nodes:[]int}
Glb_Image :: struct {buffer_view:int `json:"bufferView"`,mime_type:string `json:"mimeType"`,uri:string}
Glb_Texture :: struct {source:int}
Glb_Texture_Info :: struct {index:Maybe(int)}
Glb_Normal_Texture_Info :: struct {index:Maybe(int),scale:Maybe(f32)}
Glb_Pbr :: struct {
	base_color_texture: Glb_Texture_Info `json:"baseColorTexture"`,
	metallic_roughness_texture: Glb_Texture_Info `json:"metallicRoughnessTexture"`,
	base_color_factor: [4]f32 `json:"baseColorFactor"`,
	metallic_factor: Maybe(f32) `json:"metallicFactor"`,
	roughness_factor: Maybe(f32) `json:"roughnessFactor"`,
}
Glb_Material :: struct {name:string,pbr:Glb_Pbr `json:"pbrMetallicRoughness"`,normal_texture:Glb_Normal_Texture_Info `json:"normalTexture"`,alpha_mode:string `json:"alphaMode"`,alpha_cutoff:f32 `json:"alphaCutoff"`}
Glb_Node :: struct {
	mesh: Maybe(int),
	skin: Maybe(int),
	children: []int,
	transform_matrix: [16]f32 `json:"matrix"`,
	translation: [3]f32,
	rotation: [4]f32,
	scale: [3]f32,
}
Glb_Document :: struct {
	buffer_views: []Glb_Buffer_View `json:"bufferViews"`,
	accessors: []Glb_Accessor,
	meshes: []Glb_Source_Mesh,
	animations: []Glb_Source_Animation,
	images: []Glb_Image,
	textures: []Glb_Texture,
	materials: []Glb_Material,
	nodes: []Glb_Node,
	skins: []Glb_Skin_Source,
	scenes: []Glb_Scene_Source,
	scene: int,
}

Glb_Mat4 :: [16]f32
Glb_Mesh_Instance :: struct {mesh,node,skin:int,transform:Glb_Mat4}
glb_mat4_identity :: proc()->Glb_Mat4 {return {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1}}
glb_mat4_multiply :: proc(a,b:Glb_Mat4)->Glb_Mat4 {
	r:Glb_Mat4
	for column in 0..<4 {for row in 0..<4 {for k in 0..<4 do r[column*4+row]+=a[k*4+row]*b[column*4+k]}}
	return r
}
glb_mat4_inverse_affine :: proc(m:Glb_Mat4)->(Glb_Mat4,bool) {
	a,b,c:=m[0],m[4],m[8];d,e,f:=m[1],m[5],m[9];g,h,i:=m[2],m[6],m[10]
	determinant:=a*(e*i-f*h)-b*(d*i-f*g)+c*(d*h-e*g)
	if math.abs(determinant)<.0000001 do return {},false
	inverse_determinant:=1/determinant
	r:=Glb_Mat4{
		(e*i-f*h)*inverse_determinant,(f*g-d*i)*inverse_determinant,(d*h-e*g)*inverse_determinant,0,
		(c*h-b*i)*inverse_determinant,(a*i-c*g)*inverse_determinant,(b*g-a*h)*inverse_determinant,0,
		(b*f-c*e)*inverse_determinant,(c*d-a*f)*inverse_determinant,(a*e-b*d)*inverse_determinant,0,
		0,0,0,1,
	}
	t:=Vec3{m[12],m[13],m[14]};r[12]=-(r[0]*t.x+r[4]*t.y+r[8]*t.z);r[13]=-(r[1]*t.x+r[5]*t.y+r[9]*t.z);r[14]=-(r[2]*t.x+r[6]*t.y+r[10]*t.z)
	return r,true
}
glb_node_local_transform :: proc(node:^Glb_Node)->Glb_Mat4 {
	for value in node.transform_matrix do if value!=0 do return node.transform_matrix
	t:=node.translation;s:=node.scale;q:=node.rotation
	if s[0]==0&&s[1]==0&&s[2]==0 do s={1,1,1}
	if q[0]==0&&q[1]==0&&q[2]==0&&q[3]==0 do q[3]=1
	x,y,z,w:=q[0],q[1],q[2],q[3]
	// glTF matrices are column-major and node TRS composes as T * R * S.
	return {
		(1-2*y*y-2*z*z)*s[0],(2*x*y+2*z*w)*s[0],(2*x*z-2*y*w)*s[0],0,
		(2*x*y-2*z*w)*s[1],(1-2*x*x-2*z*z)*s[1],(2*y*z+2*x*w)*s[1],0,
		(2*x*z+2*y*w)*s[2],(2*y*z-2*x*w)*s[2],(1-2*x*x-2*y*y)*s[2],0,
		t[0],t[1],t[2],1,
	}
}
glb_transform_point :: proc(m:Glb_Mat4,v:Vec3)->Vec3 {
	return {m[0]*v.x+m[4]*v.y+m[8]*v.z+m[12],m[1]*v.x+m[5]*v.y+m[9]*v.z+m[13],m[2]*v.x+m[6]*v.y+m[10]*v.z+m[14]}
}
glb_resolve_node_transform :: proc(nodes:[]Glb_Node,index:int,parent:Glb_Mat4,instances:^[dynamic]Glb_Mesh_Instance,referenced:[]bool,visiting:[]bool) {
	if index<0||index>=len(nodes)||visiting[index] do return
	visiting[index]=true
	world:=glb_mat4_multiply(parent,glb_node_local_transform(&nodes[index]))
	if mesh_index,mesh_ok:=nodes[index].mesh.(int);mesh_ok {skin_index:=-1;if value,ok:=nodes[index].skin.(int);ok do skin_index=value;if mesh_index>=0&&mesh_index<len(referenced) {append(instances,Glb_Mesh_Instance{mesh_index,index,skin_index,world});referenced[mesh_index]=true}}
	for child in nodes[index].children do glb_resolve_node_transform(nodes,child,world,instances,referenced,visiting)
	visiting[index]=false
}

glb_has_animation :: proc(mesh:^Glb_Mesh, name:string)->bool {for animation in mesh.animations do if animation==name do return true;return false}

glb_parent_directory :: proc(path:string)->string {
	for i:=len(path)-1;i>=0;i-=1 do if path[i]=='/'||path[i]=='\\' do return path[:i]
	return "."
}

read_u32_le :: proc(data: []u8, offset: int) -> (u32, bool) {
	if offset < 0 || offset + 4 > len(data) do return 0, false
	return u32(data[offset]) | u32(data[offset+1])<<8 | u32(data[offset+2])<<16 | u32(data[offset+3])<<24, true
}
read_f32_le :: proc(data: []u8, offset: int) -> (f32, bool) {
	bits, ok := read_u32_le(data, offset)
	if !ok do return 0, false
	return transmute(f32)bits, true
}

glb_accessor_layout :: proc(doc:^Glb_Document,index,components,component_size:int)->(Glb_Accessor,int,int,bool) {
	if index<0||index>=len(doc.accessors) do return {},0,0,false
	a:=doc.accessors[index];if a.buffer_view<0||a.buffer_view>=len(doc.buffer_views) do return {},0,0,false
	v:=doc.buffer_views[a.buffer_view];stride:=v.byte_stride;if stride==0 do stride=components*component_size
	return a,v.byte_offset+a.byte_offset,stride,stride>=components*component_size
}
glb_read_scalar_f32 :: proc(doc:^Glb_Document,bin:[]u8,index:int)->([]f32,bool) {
	a,start,stride,ok:=glb_accessor_layout(doc,index,1,4);if !ok||a.kind!="SCALAR"||a.component_type!=5126 do return nil,false
	out:=make([]f32,a.count);for i in 0..<a.count {v,vok:=read_f32_le(bin,start+i*stride);if !vok do return nil,false;out[i]=v};return out,true
}
glb_read_vec4_f32 :: proc(doc:^Glb_Document,bin:[]u8,index,count:int)->([]Vec4,bool) {
	a,start,stride,ok:=glb_accessor_layout(doc,index,4,4);if !ok||a.kind!="VEC4"||a.component_type!=5126||a.count!=count do return nil,false
	out:=make([]Vec4,count);for i in 0..<count {at:=start+i*stride;x,xok:=read_f32_le(bin,at);y,yok:=read_f32_le(bin,at+4);z,zok:=read_f32_le(bin,at+8);w,wok:=read_f32_le(bin,at+12);if !xok||!yok||!zok||!wok do return nil,false;out[i]={x,y,z,w}};return out,true
}
glb_read_vec3_values :: proc(doc:^Glb_Document,bin:[]u8,index,count:int)->([]Vec4,bool) {
	a,start,stride,ok:=glb_accessor_layout(doc,index,3,4);if !ok||a.kind!="VEC3"||a.component_type!=5126||a.count!=count do return nil,false
	out:=make([]Vec4,count);for i in 0..<count {at:=start+i*stride;x,xok:=read_f32_le(bin,at);y,yok:=read_f32_le(bin,at+4);z,zok:=read_f32_le(bin,at+8);if !xok||!yok||!zok do return nil,false;out[i]={x,y,z,0}};return out,true
}
glb_read_mat4 :: proc(doc:^Glb_Document,bin:[]u8,index,count:int)->([]Glb_Mat4,bool) {
	a,start,stride,ok:=glb_accessor_layout(doc,index,16,4);if !ok||a.kind!="MAT4"||a.component_type!=5126||a.count!=count do return nil,false
	out:=make([]Glb_Mat4,count);for i in 0..<count {for j in 0..<16 {v,vok:=read_f32_le(bin,start+i*stride+j*4);if !vok do return nil,false;out[i][j]=v}};return out,true
}
glb_read_joints :: proc(doc:^Glb_Document,bin:[]u8,index,count:int)->([]Glb_Joints,bool) {
	if index<0||index>=len(doc.accessors) do return nil,false;source:=doc.accessors[index];size:=source.component_type==5121?1:source.component_type==5123?2:0;if size==0 do return nil,false
	a,start,stride,ok:=glb_accessor_layout(doc,index,4,size);if !ok||a.kind!="VEC4"||a.count!=count do return nil,false
	out:=make([]Glb_Joints,count);for i in 0..<count {for j in 0..<4 {at:=start+i*stride+j*size;if size==1 {if at>=len(bin) do return nil,false;out[i][j]=u16(bin[at])}else{if at+2>len(bin) do return nil,false;out[i][j]=u16(bin[at])|u16(bin[at+1])<<8}}};return out,true
}

glb_node_bind_trs :: proc(node:^Glb_Node)->Glb_TRS {t:=Vec3{node.translation[0],node.translation[1],node.translation[2]};s:=Vec3{node.scale[0],node.scale[1],node.scale[2]};if s.x==0&&s.y==0&&s.z==0 do s={1,1,1};q:=Vec4{node.rotation[0],node.rotation[1],node.rotation[2],node.rotation[3]};if q.x==0&&q.y==0&&q.z==0&&q.w==0 do q.w=1;return {t,q,s}}
glb_trs_matrix :: proc(v:Glb_TRS)->Glb_Mat4 {n:=Glb_Node{translation={v.translation.x,v.translation.y,v.translation.z},rotation={v.rotation.x,v.rotation.y,v.rotation.z,v.rotation.w},scale={v.scale.x,v.scale.y,v.scale.z}};return glb_node_local_transform(&n)}
glb_vec4_normalize :: proc(q:Vec4)->Vec4 {l:=f32(math.sqrt(f64(q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w)));if l<.000001 do return {0,0,0,1};return {q.x/l,q.y/l,q.z/l,q.w/l}}
glb_quat_slerp :: proc(a,b:Vec4,t:f32)->Vec4 {bb:=b;dot:=a.x*b.x+a.y*b.y+a.z*b.z+a.w*b.w;if dot<0 {dot=-dot;bb={-b.x,-b.y,-b.z,-b.w}};if dot>.9995 do return glb_vec4_normalize({a.x+(bb.x-a.x)*t,a.y+(bb.y-a.y)*t,a.z+(bb.z-a.z)*t,a.w+(bb.w-a.w)*t});theta:=f32(math.acos(f64(clamp(dot,-1,1))));s:=f32(math.sin(f64(theta)));wa:=f32(math.sin(f64((1-t)*theta)))/s;wb:=f32(math.sin(f64(t*theta)))/s;return {a.x*wa+bb.x*wb,a.y*wa+bb.y*wb,a.z*wa+bb.z*wb,a.w*wa+bb.w*wb}}
glb_clip_index :: proc(mesh:^Glb_Mesh,name:string)->int {for clip,i in mesh.clips do if clip.name==name do return i;return -1}
glb_clip_index_suffix :: proc(mesh:^Glb_Mesh,name:string)->int {if exact:=glb_clip_index(mesh,name);exact>=0 do return exact;for clip,i in mesh.clips do if strings.has_suffix(clip.name,name) do return i;return -1}
glb_clip_duration :: proc(mesh:^Glb_Mesh,name:string)->f32 {i:=glb_clip_index(mesh,name);return i>=0?mesh.clips[i].duration:0}
glb_sample_pose :: proc(mesh:^Glb_Mesh,clip_index:int,time:f32,loop:bool,out:[]Glb_TRS)->bool {
	if clip_index<0||clip_index>=len(mesh.clips)||len(out)!=len(mesh.nodes) do return false;for node,i in mesh.nodes do out[i]=node.bind;clip:=&mesh.clips[clip_index];sample_time:=time;if loop&&clip.duration>0 do sample_time-=f32(math.floor(f64(sample_time/clip.duration)))*clip.duration;sample_time=clamp(sample_time,0,clip.duration)
	for &channel in clip.channels {if channel.node<0||channel.node>=len(out)||len(channel.times)==0 do continue;hi:=1;for hi<len(channel.times)&&channel.times[hi]<sample_time do hi+=1;lo:=max(0,hi-1);hi=min(hi,len(channel.times)-1);mix:f32=0;if channel.interpolation==.Linear&&channel.times[hi]>channel.times[lo] do mix=(sample_time-channel.times[lo])/(channel.times[hi]-channel.times[lo]);a,b:=channel.values[lo],channel.values[hi];switch channel.path {case .Translation:v:=Vec4{a.x+(b.x-a.x)*mix,a.y+(b.y-a.y)*mix,a.z+(b.z-a.z)*mix,0};out[channel.node].translation={v.x,v.y,v.z};case .Scale:v:=Vec4{a.x+(b.x-a.x)*mix,a.y+(b.y-a.y)*mix,a.z+(b.z-a.z)*mix,0};out[channel.node].scale={v.x,v.y,v.z};case .Rotation:out[channel.node].rotation=glb_quat_slerp(a,b,mix)}};return true
}
glb_blend_pose :: proc(a,b:[]Glb_TRS,t:f32,out:[]Glb_TRS) {for i in 0..<min(len(a),min(len(b),len(out))) {out[i].translation={a[i].translation.x+(b[i].translation.x-a[i].translation.x)*t,a[i].translation.y+(b[i].translation.y-a[i].translation.y)*t,a[i].translation.z+(b[i].translation.z-a[i].translation.z)*t};out[i].scale={a[i].scale.x+(b[i].scale.x-a[i].scale.x)*t,a[i].scale.y+(b[i].scale.y-a[i].scale.y)*t,a[i].scale.z+(b[i].scale.z-a[i].scale.z)*t};out[i].rotation=glb_quat_slerp(a[i].rotation,b[i].rotation,t)}}
glb_resolve_pose_node :: proc(mesh:^Glb_Mesh,pose:[]Glb_TRS,index:int,world:[]Glb_Mat4,done,visiting:[]bool)->bool {if index<0||index>=len(mesh.nodes)||visiting[index] do return false;if done[index] do return true;visiting[index]=true;local:=glb_trs_matrix(pose[index]);parent:=mesh.nodes[index].parent;if parent>=0 {if !glb_resolve_pose_node(mesh,pose,parent,world,done,visiting) do return false;world[index]=glb_mat4_multiply(world[parent],local)}else{world[index]=local};visiting[index]=false;done[index]=true;return true}
glb_pose_palette :: proc(mesh:^Glb_Mesh,pose:[]Glb_TRS,out:[]Glb_Mat4)->bool {if len(mesh.skin.joints)==0||len(out)<len(mesh.skin.joints)||len(pose)!=len(mesh.nodes) do return false;world:=make([]Glb_Mat4,len(mesh.nodes),context.temp_allocator);done:=make([]bool,len(mesh.nodes),context.temp_allocator);visiting:=make([]bool,len(mesh.nodes),context.temp_allocator);mesh_inverse:=glb_mat4_identity();if mesh.skin.mesh_node>=0 {if mesh.skin.mesh_node>=len(world)||!glb_resolve_pose_node(mesh,pose,mesh.skin.mesh_node,world,done,visiting) do return false;ok:bool;mesh_inverse,ok=glb_mat4_inverse_affine(world[mesh.skin.mesh_node]);if !ok do return false};for joint,i in mesh.skin.joints {if joint<0||joint>=len(world)||!glb_resolve_pose_node(mesh,pose,joint,world,done,visiting) do return false;out[i]=glb_mat4_multiply(mesh_inverse,glb_mat4_multiply(world[joint],mesh.skin.inverse_bind[i]))};return true}

glb_load :: proc(path: string, allocator := context.allocator) -> (Glb_Mesh, bool) {
	result: Glb_Mesh
	data, file_error := os.read_entire_file_from_path(path, context.temp_allocator)
	if file_error != nil || len(data) < 20 do return result, false
	magic, magic_ok := read_u32_le(data, 0)
	version, version_ok := read_u32_le(data, 4)
	declared_length, length_ok := read_u32_le(data, 8)
	if !magic_ok || !version_ok || !length_ok || magic != GLB_MAGIC || version != 2 || int(declared_length) > len(data) do return result, false

	json_bytes, binary_bytes: []u8
	offset := 12
	for offset + 8 <= int(declared_length) {
		chunk_length, length_read := read_u32_le(data, offset)
		chunk_type, type_read := read_u32_le(data, offset + 4)
		if !length_read || !type_read || offset + 8 + int(chunk_length) > int(declared_length) do return result, false
		chunk := data[offset+8:offset+8+int(chunk_length)]
		if chunk_type == GLB_JSON_CHUNK do json_bytes = chunk
		if chunk_type == GLB_BIN_CHUNK do binary_bytes = chunk
		offset += 8 + int(chunk_length)
	}
	if len(json_bytes) == 0 || len(binary_bytes) == 0 do return result, false

	doc: Glb_Document
	if json.unmarshal(json_bytes, &doc, allocator=allocator) != nil do return result, false
	result.vertices = make([dynamic]Vec3, 0, 1024, allocator)
	result.texcoords = make([dynamic]Vec2, 0, 1024, allocator)
	result.indices = make([dynamic]u32, 0, 3072, allocator)
	result.primitives = make([dynamic]Glb_Primitive_Range,0,32,allocator)
	result.textures = make([dynamic]Glb_Texture_Data,0,len(doc.images),allocator)
	for source_image in doc.images {
		decoded:Glb_Texture_Data
		if source_image.buffer_view>=0&&source_image.buffer_view<len(doc.buffer_views) {
			view:=doc.buffer_views[source_image.buffer_view];start:=view.byte_offset;end:=start+view.byte_length
			if start>=0&&end<=len(binary_bytes) {
				img,err:=image.load_from_bytes(binary_bytes[start:end],{.alpha_add_if_missing},allocator)
				if err==nil&&img!=nil {decoded.width=img.width;decoded.height=img.height;decoded.pixels=make([dynamic]u8,len(img.pixels.buf),allocator);copy(decoded.pixels[:],img.pixels.buf[:]);image.destroy(img,allocator)}
			}
		}
		if len(decoded.pixels)==0&&source_image.uri!="" {
			image_path,path_error:=filepath.join([]string{glb_parent_directory(path),source_image.uri},context.temp_allocator)
			if path_error==nil {
				img,err:=image.load(image_path,{.alpha_add_if_missing},allocator)
				if err==nil&&img!=nil {decoded.width=img.width;decoded.height=img.height;decoded.pixels=make([dynamic]u8,len(img.pixels.buf),allocator);copy(decoded.pixels[:],img.pixels.buf[:]);image.destroy(img,allocator)}
			}
		}
		append(&result.textures,decoded)
	}
	result.animations = make([dynamic]string, 0, len(doc.animations), allocator)
	for animation in doc.animations do append(&result.animations, animation.name)
	result.nodes=make([dynamic]Glb_Runtime_Node,len(doc.nodes),len(doc.nodes),allocator);for &runtime,i in result.nodes {runtime.parent=-1;runtime.bind=glb_node_bind_trs(&doc.nodes[i])};for node,i in doc.nodes {for child in node.children {if child>=0&&child<len(result.nodes) do result.nodes[child].parent=i}}
	if len(doc.skins)>1 do return {},false
	if len(doc.skins)==1 {
		source_skin:=doc.skins[0];if len(source_skin.joints)==0||len(source_skin.joints)>GLB_MAX_JOINTS do return {},false
		inverse,ib_ok:=glb_read_mat4(&doc,binary_bytes,source_skin.inverse_bind_matrices,len(source_skin.joints));if !ib_ok do return {},false
		result.skin.joints=make([dynamic]int,len(source_skin.joints),len(source_skin.joints),allocator);copy(result.skin.joints[:],source_skin.joints);result.skin.inverse_bind=make([dynamic]Glb_Mat4,len(inverse),len(inverse),allocator);copy(result.skin.inverse_bind[:],inverse);result.skin.mesh_node=-1
		for joint in result.skin.joints do if joint<0||joint>=len(result.nodes) do return {},false
	}
	result.clips=make([dynamic]Glb_Animation_Clip,0,len(doc.animations),allocator)
	for &source_animation in doc.animations {
		clip:=Glb_Animation_Clip{name=source_animation.name,channels=make([dynamic]Glb_Animation_Channel,0,len(source_animation.channels),allocator)}
		for source_channel in source_animation.channels {
			if source_channel.sampler<0||source_channel.sampler>=len(source_animation.samplers)||source_channel.target.node<0||source_channel.target.node>=len(result.nodes) do return {},false
			sampler:=source_animation.samplers[source_channel.sampler];interpolation:=Glb_Interpolation.Linear;if sampler.interpolation=="STEP" do interpolation=.Step;if sampler.interpolation!=""&&sampler.interpolation!="LINEAR"&&sampler.interpolation!="STEP" do return {},false
			times,times_ok:=glb_read_scalar_f32(&doc,binary_bytes,sampler.input);if !times_ok||len(times)==0 do return {},false
			path:Glb_Animation_Path;values:[]Vec4;values_ok:=false;switch source_channel.target.path {case "translation":path=.Translation;values,values_ok=glb_read_vec3_values(&doc,binary_bytes,sampler.output,len(times));case "rotation":path=.Rotation;values,values_ok=glb_read_vec4_f32(&doc,binary_bytes,sampler.output,len(times));case "scale":path=.Scale;values,values_ok=glb_read_vec3_values(&doc,binary_bytes,sampler.output,len(times));case:return {},false};if !values_ok do return {},false
			channel:=Glb_Animation_Channel{node=source_channel.target.node,path=path,interpolation=interpolation,times=make([dynamic]f32,len(times),len(times),allocator),values=make([dynamic]Vec4,len(values),len(values),allocator)};copy(channel.times[:],times);copy(channel.values[:],values);append(&clip.channels,channel);clip.duration=max(clip.duration,times[len(times)-1])
		};append(&result.clips,clip)
	}
	result.min = {math.inf_f32(1), math.inf_f32(1), math.inf_f32(1)}
	result.max = {math.inf_f32(-1), math.inf_f32(-1), math.inf_f32(-1)}
	mesh_instances:=make([dynamic]Glb_Mesh_Instance,0,len(doc.nodes),context.temp_allocator)
	mesh_referenced:=make([]bool,len(doc.meshes),context.temp_allocator)
	is_child:=make([]bool,len(doc.nodes),context.temp_allocator)
	visiting:=make([]bool,len(doc.nodes),context.temp_allocator)
	for node in doc.nodes {for child in node.children do if child>=0&&child<len(is_child) do is_child[child]=true}
	if len(doc.scenes)>0&&doc.scene>=0&&doc.scene<len(doc.scenes) {for node_index in doc.scenes[doc.scene].nodes do glb_resolve_node_transform(doc.nodes,node_index,glb_mat4_identity(),&mesh_instances,mesh_referenced,visiting)}else{for _,node_index in doc.nodes do if !is_child[node_index] do glb_resolve_node_transform(doc.nodes,node_index,glb_mat4_identity(),&mesh_instances,mesh_referenced,visiting)}
	// Meshes omitted from an authored node graph are intentionally unused. Some
	// Kenney files retain duplicate drawer or pillow meshes that must not appear
	// at the origin. Only node-less minimal files fall back to identity instances.
	if len(doc.nodes)==0 {for _,mesh_index in doc.meshes do append(&mesh_instances,Glb_Mesh_Instance{mesh_index,-1,-1,glb_mat4_identity()})}

	for instance in mesh_instances {
		if instance.skin>=0 {if instance.skin!=0||len(result.skin.joints)==0 do return {},false;if result.skin.mesh_node<0 do result.skin.mesh_node=instance.node}
		source_mesh:=doc.meshes[instance.mesh]
		for primitive in source_mesh.primitives {
			// glTF omits `mode` for its default TRIANGLES value; JSON leaves omitted integers at zero.
			if (primitive.mode != 0 && primitive.mode != 4) || primitive.attributes.position < 0 || primitive.attributes.position >= len(doc.accessors) do continue
			position_accessor := doc.accessors[primitive.attributes.position]
			if position_accessor.kind != "VEC3" || position_accessor.component_type != 5126 || position_accessor.buffer_view < 0 || position_accessor.buffer_view >= len(doc.buffer_views) do continue
			view := doc.buffer_views[position_accessor.buffer_view]
			stride := view.byte_stride
			if stride == 0 do stride = 12
			if stride < 12 do continue
			base_vertex := u32(len(result.vertices))
			first_index:=len(result.indices)
			positions_start := view.byte_offset + position_accessor.byte_offset
			positions_ok := true
			for i in 0..<position_accessor.count {
				at := positions_start + i*stride
				x, x_ok := read_f32_le(binary_bytes, at)
				y, y_ok := read_f32_le(binary_bytes, at+4)
				z, z_ok := read_f32_le(binary_bytes, at+8)
				if !x_ok || !y_ok || !z_ok {positions_ok=false;break}
				v := Vec3{x,y,z};if instance.skin<0 do v=glb_transform_point(instance.transform,v);append(&result.vertices, v)
				result.min={min(result.min.x,v.x),min(result.min.y,v.y),min(result.min.z,v.z)}
				result.max={max(result.max.x,v.x),max(result.max.y,v.y),max(result.max.z,v.z)}
			}
			if !positions_ok do return {}, false
			if instance.skin>=0 {joints,joints_ok:=glb_read_joints(&doc,binary_bytes,primitive.attributes.joints_0,position_accessor.count);weights,weights_ok:=glb_read_vec4_f32(&doc,binary_bytes,primitive.attributes.weights_0,position_accessor.count);if !joints_ok||!weights_ok do return {},false;for i in 0..<position_accessor.count {sum:=weights[i].x+weights[i].y+weights[i].z+weights[i].w;if sum<=.000001 do return {},false;weights[i]={weights[i].x/sum,weights[i].y/sum,weights[i].z/sum,weights[i].w/sum};for joint in joints[i] do if int(joint)>=len(result.skin.joints) do return {},false;append(&result.joints,joints[i]);append(&result.weights,weights[i])}}else{for _ in 0..<position_accessor.count {append(&result.joints,Glb_Joints{});append(&result.weights,Vec4{1,0,0,0})}}
			uv_accessor_index:=primitive.attributes.texcoord_0
			if uv_accessor_index>=0&&uv_accessor_index<len(doc.accessors) {
				uv_accessor:=doc.accessors[uv_accessor_index]
				if uv_accessor.kind=="VEC2"&&uv_accessor.component_type==5126&&uv_accessor.count==position_accessor.count&&uv_accessor.buffer_view>=0&&uv_accessor.buffer_view<len(doc.buffer_views) {
					uv_view:=doc.buffer_views[uv_accessor.buffer_view];uv_stride:=uv_view.byte_stride;if uv_stride==0 do uv_stride=8
					for i in 0..<uv_accessor.count {at:=uv_view.byte_offset+uv_accessor.byte_offset+i*uv_stride;u,uok:=read_f32_le(binary_bytes,at);v,vok:=read_f32_le(binary_bytes,at+4);if !uok||!vok do return {},false;append(&result.texcoords,Vec2{u,v})}
				} else {for _ in 0..<position_accessor.count do append(&result.texcoords,Vec2{})}
			} else {for _ in 0..<position_accessor.count do append(&result.texcoords,Vec2{})}
			if primitive.indices < 0 {
				for i in 0..<position_accessor.count do append(&result.indices, base_vertex+u32(i))
			} else {
			if primitive.indices >= len(doc.accessors) do return {}, false
			index_accessor := doc.accessors[primitive.indices]
			if index_accessor.kind != "SCALAR" || index_accessor.buffer_view < 0 || index_accessor.buffer_view >= len(doc.buffer_views) do return {}, false
			index_view := doc.buffer_views[index_accessor.buffer_view]
			component_size := index_accessor.component_type == 5121 ? 1 : index_accessor.component_type == 5123 ? 2 : index_accessor.component_type == 5125 ? 4 : 0
			if component_size == 0 do return {}, false
			index_stride := index_view.byte_stride
			if index_stride == 0 do index_stride = component_size
			indices_start := index_view.byte_offset + index_accessor.byte_offset
			for i in 0..<index_accessor.count {
				at := indices_start+i*index_stride
				index: u32
				switch component_size {
				case 1: if at >= len(binary_bytes) do return {},false; index=u32(binary_bytes[at])
				case 2: if at+2 > len(binary_bytes) do return {},false; index=u32(binary_bytes[at])|u32(binary_bytes[at+1])<<8
				case 4: value, ok := read_u32_le(binary_bytes,at);if !ok do return {},false;index=value
				}
				if index >= u32(position_accessor.count) do return {}, false
				append(&result.indices,base_vertex+index)
			}
			}
			texture_index,normal_texture,roughness_texture:=-1,-1,-1;base_color:=[4]f32{1,1,1,1};metallic_factor,roughness_factor,normal_scale:=f32(1),f32(1),f32(1);alpha_mode:=0;alpha_cutoff:=f32(.5)
			if primitive.material>=0&&primitive.material<len(doc.materials) {
				material:=doc.materials[primitive.material];factor:=material.pbr.base_color_factor;if factor[0]!=0||factor[1]!=0||factor[2]!=0||factor[3]!=0 do base_color=factor
				if ti,ok:=material.pbr.base_color_texture.index.(int);ok&&ti>=0&&ti<len(doc.textures) {source:=doc.textures[ti].source;if source>=0&&source<len(result.textures) do texture_index=source}
				if ti,ok:=material.normal_texture.index.(int);ok&&ti>=0&&ti<len(doc.textures) {source:=doc.textures[ti].source;if source>=0&&source<len(result.textures) do normal_texture=source}
				if ti,ok:=material.pbr.metallic_roughness_texture.index.(int);ok&&ti>=0&&ti<len(doc.textures) {source:=doc.textures[ti].source;if source>=0&&source<len(result.textures) do roughness_texture=source}
				if value,ok:=material.pbr.metallic_factor.(f32);ok do metallic_factor=value;if value,ok:=material.pbr.roughness_factor.(f32);ok do roughness_factor=value;if value,ok:=material.normal_texture.scale.(f32);ok do normal_scale=value
				if material.alpha_mode=="MASK" {alpha_mode=1;if material.alpha_cutoff>0 do alpha_cutoff=material.alpha_cutoff}else if material.alpha_mode=="BLEND" {alpha_mode=2}
			}
			material_name:="";if primitive.material>=0&&primitive.material<len(doc.materials) do material_name=doc.materials[primitive.material].name
			append(&result.primitives,Glb_Primitive_Range{first_index,len(result.indices)-first_index,texture_index,base_color});append(&result.normal_textures,normal_texture);append(&result.roughness_textures,roughness_texture);append(&result.metallic_factors,metallic_factor);append(&result.roughness_factors,roughness_factor);append(&result.normal_scales,normal_scale);append(&result.alpha_modes,alpha_mode);append(&result.alpha_cutoffs,alpha_cutoff);append(&result.material_names,material_name)
		}
	}
	// POSITION bounds remain in mesh-local space. Joint palettes belong only to
	// vertex deformation; applying them here can incorrectly inflate static bounds
	// for rigs whose armature node has a non-identity transform.
	result.ready = glb_mesh_ready(&result)
	return result, result.ready
}

glb_mesh_ready :: proc(mesh:^Glb_Mesh)->bool {
	return mesh!=nil&&len(mesh.vertices)>0&&len(mesh.indices)>=3&&len(mesh.indices)%3==0
}
