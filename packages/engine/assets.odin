package engine

import "core:os"

Shader_Stage :: enum {
	Compute,
	Vertex,
	Fragment,
}

Shader_Asset :: struct {
	name: string,
	stage: Shader_Stage,
	source_path: string,
	spirv_path: string,
	entry_point: string,
}

Slang_Shader_Manifest :: struct {
	source_path: string,
	stage: Shader_Stage,
	entry_point: string,
	spirv_path: string,
	spirv_version: string,
	target_environment: string,
}

SLANG_MANIFEST_PATH :: "build/shaders/slang-manifest.txt"

SHADERS :: [?]Shader_Asset {
	{"gray_scott_step", .Compute, "assets/shaders/gray_scott_step.slang", "build/shaders/gray_scott_step.spv", "main"},
	{"gray_scott_present", .Fragment, "assets/shaders/gray_scott_present.slang", "build/shaders/gray_scott_present.spv", "fragment_main"},
	{"ui_vertex", .Vertex, "assets/shaders/ui_vertex.slang", "build/shaders/ui_vertex.spv", "main"},
	{"ui", .Fragment, "assets/shaders/ui.slang", "build/shaders/ui.spv", "fragment_main"},
}

shader_compile_command_hint :: proc(shader: Shader_Asset, out: []u8) -> string {
	stage := "compute"
	switch shader.stage {
	case .Vertex:
		stage = "vertex"
	case .Fragment:
		stage = "fragment"
	case .Compute:
		stage = "compute"
	}

	prefix := "slangc "
	mid := " -target spirv -profile spirv_1_6 -stage "
	entry := " -entry "
	output := " -o "
	parts := []string{prefix, shader.source_path, mid, stage, entry, shader.entry_point, output, shader.spirv_path}

	cursor := 0
	for part in parts {
		for ch in transmute([]u8)part {
			if cursor >= len(out) {
				return string(out[:cursor])
			}
			out[cursor] = ch
			cursor += 1
		}
	}
	return string(out[:cursor])
}

shader_spirv_path :: proc(source_path: string, stage: Shader_Stage, entry_point: string, fallback: string) -> string {
	manifest := shader_manifest_find_spirv(source_path, stage, entry_point)
	if len(manifest) > 0 {
		return manifest
	}
	return fallback
}

shader_manifest_find_spirv :: proc(source_path: string, stage: Shader_Stage, entry_point: string) -> string {
	bytes, err := os.read_entire_file_from_path(SLANG_MANIFEST_PATH, context.temp_allocator)
	if err != nil {
		return ""
	}
	defer delete(bytes, context.temp_allocator)

	line_start := 0
	for i := 0; i <= len(bytes); i += 1 {
		if i == len(bytes) || bytes[i] == '\n' {
			line_end := i
			if line_end > line_start && bytes[line_end - 1] == '\r' {
				line_end -= 1
			}
			if line_end > line_start {
				parsed, ok := shader_manifest_parse_line(string(bytes[line_start:line_end]))
				if ok && parsed.source_path == source_path && parsed.stage == stage {
					if len(entry_point) == 0 || parsed.entry_point == entry_point {
						return parsed.spirv_path
					}
				}
			}
			line_start = i + 1
		}
	}
	return ""
}

shader_manifest_parse_line :: proc(line: string) -> (Slang_Shader_Manifest, bool) {
	result: Slang_Shader_Manifest
	parts: [6]string
	count := 0
	start := 0
	for i := 0; i <= len(line); i += 1 {
		if i == len(line) || line[i] == '|' {
			if count < 6 {
				parts[count] = line[start:i]
				count += 1
			}
			start = i + 1
			if i == len(line) {
				break
			}
		}
	}
	if count < 4 {
		return result, false
	}

	result.source_path = parts[0]
	switch parts[1] {
	case "compute":
		result.stage = .Compute
	case "vertex":
		result.stage = .Vertex
	case "fragment":
		result.stage = .Fragment
	case:
		return result, false
	}
	result.entry_point = parts[2]
	result.spirv_path = parts[3]
	if count >= 6 {
		result.spirv_version = parts[4]
		result.target_environment = parts[5]
	}
	return result, true
}
