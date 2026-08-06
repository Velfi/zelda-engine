package wireframe

// Matches assets/shaders/wireframe.slang. Submit six unit-quad vertices and
// one Line_Instance per edge with VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST.
Line_Vertex :: struct {
    parameter: [2]f32,
}
Line_Instance :: struct {
    start_position, end_position: [3]f32,
    start_color, end_color:       [4]f32,
}
Push :: struct {
    view_projection: [16]f32,
    viewport:        [2]f32,
    line_width:      f32,
    _padding:        f32,
}

UNIT_RIBBON_VERTICES := [6]Line_Vertex{{{0, -1}}, {{1, -1}}, {{1, 1}}, {{0, -1}}, {{1, 1}}, {{0, 1}}}
#assert(size_of(Line_Instance) == 56)
#assert(size_of(Push) == 80)
