package render_graph

MAX_GRAPH_PASSES :: 16
MAX_PASS_DEPENDENCIES :: 8

Pass_Execute :: #type proc(user_data: rawptr)

Pass :: struct {
    name:             string,
    execute:          Pass_Execute,
    dependencies:     [MAX_PASS_DEPENDENCIES]int,
    dependency_count: int,
}

Graph :: struct {
    passes: [MAX_GRAPH_PASSES]Pass,
    count:  int,
}

reset :: proc(graph: ^Graph) {
    if graph == nil do return
    graph^ = {}
}

add_pass :: proc(graph: ^Graph, name: string, execute: Pass_Execute) -> int {
    if graph == nil || graph.count >= MAX_GRAPH_PASSES do return -1
    id := graph.count
    graph.passes[id] = {
        name    = name,
        execute = execute,
    }
    graph.count += 1
    return id
}

depends_on :: proc(graph: ^Graph, pass, dependency: int) -> bool {
    if graph == nil || pass < 0 || pass >= graph.count || dependency < 0 || dependency >= graph.count do return false
    entry := &graph.passes[pass]
    if entry.dependency_count >= MAX_PASS_DEPENDENCIES do return false
    entry.dependencies[entry.dependency_count] = dependency
    entry.dependency_count += 1
    return true
}

execute :: proc(graph: ^Graph, user_data: rawptr) -> bool {
    if graph == nil do return false
    done: [MAX_GRAPH_PASSES]bool
    completed := 0
    for completed < graph.count {
        progress := false
        for pass_index in 0 ..< graph.count {
            if done[pass_index] do continue
            pass := &graph.passes[pass_index]
            ready := true
            for dependency in pass.dependencies[:pass.dependency_count] {
                if !done[dependency] {
                    ready = false
                    break
                }
            }
            if !ready do continue
            if pass.execute != nil do pass.execute(user_data)
            done[pass_index] = true
            completed += 1
            progress = true
        }
        if !progress do return false
    }
    return true
}
