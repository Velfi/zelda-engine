package pdb

import "core:fmt"

pdb_debug :: proc(message: string) {
    fmt.eprintln(message)
}

pdb_debugf :: proc(format: string, args: ..any) {
    fmt.eprintf(format, ..args)
}

pdb_warnf :: proc(format: string, args: ..any) {
    fmt.eprintf(format, ..args)
}

pdb_errorf :: proc(format: string, args: ..any) {
    fmt.eprintf(format, ..args)
}

pdb_assertf :: proc(condition: bool, format: string, args: ..any) {
    fmt.assertf(condition, format, ..args)
}
