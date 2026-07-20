package engine

write_fixed_string :: proc(dst: []u8, src: string) {
	if len(dst) == 0 {
		return
	}
	n := min(len(src), len(dst) - 1)
	for i in 0 ..< n {
		dst[i] = src[i]
	}
	dst[n] = 0
}

fixed_string :: proc(buf: []u8) -> string {
	n := 0
	for n < len(buf) && buf[n] != 0 {
		n += 1
	}
	return string(buf[:n])
}
