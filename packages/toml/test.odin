#+test
package toml

import "core:slice"
import "core:strings"
import "core:testing"

import "dates"

@(test)
nil_guard_get :: proc(t: ^testing.T) {
    table: Table

    _, found := get_bool(&table, "enabled")
    testing.expectf(t, found == false, "should not crash on nullptr exception not found")
}

@(test)
unmarshal_primitives_to_struct :: proc(t: ^testing.T) {
    test_toml := `
	integer = 22
	decimal = 12.4
	boolean = true
	string = "hello"
	date = 1111-02-03
	`


    Test :: struct {
        integer: int,
        decimal: f32,
        boolean: bool,
        str:     string `toml:"string"`,
        date:    dates.Date,
    }

    test: Test
    testing.expect(t, unmarshal_string(test_toml, &test, context.temp_allocator) == .None)
    defer free_all(context.temp_allocator)

    testing.expect_value(t, test.integer, 22)
    testing.expect_value(t, test.decimal, 12.4)
    testing.expect_value(t, test.boolean, true)
    testing.expect_value(t, test.str, "hello")

    expected_date: dates.Date = {
        year  = 1111,
        month = 2,
        day   = 3,
        flags = {.date_only},
    }
    testing.expect_value(t, test.date, expected_date)
}

@(test)
unmarshal_primitives_to_map :: proc(t: ^testing.T) {
    test_toml := `
	integer = 22
	decimal = 12.4
	boolean = true
	string = "hello"
	date = 1111-02-03
	`


    test: map[string]Type
    testing.expect(t, unmarshal_string(test_toml, &test, context.temp_allocator) == .None)
    defer free_all(context.temp_allocator)

    testing.expect_value(t, test["integer"], 22)
    testing.expect_value(t, test["decimal"], 12.4)
    testing.expect_value(t, test["boolean"], true)
    testing.expect_value(t, test["string"], "hello")

    expected_date: dates.Date = {
        year  = 1111,
        month = 2,
        day   = 3,
        flags = {.date_only},
    }
    testing.expect_value(t, test["date"], expected_date)
}

@(test)
unmarshal_subtables_to_struct :: proc(t: ^testing.T) {
    test_toml := `
	[table1]
	x = 1

	[table2]
	x = 2

	[table3.table4]
	x = 3
	`


    Test :: struct {
        table1: struct {
            x: int,
        },
        table2: struct {
            x: int,
        },
        table3: struct {
            table4: struct {
                x: int,
            },
        },
    }

    test: Test
    testing.expect(t, unmarshal_string(test_toml, &test, context.temp_allocator) == .None)
    defer free_all(context.temp_allocator)

    testing.expect_value(t, test.table1.x, 1)
    testing.expect_value(t, test.table2.x, 2)
    testing.expect_value(t, test.table3.table4.x, 3)
}

@(test)
unmarshal_subtables_to_map :: proc(t: ^testing.T) {
    test_toml := `
	[table1]
	x = 123

	[table2]
	x = 345

	[table3.table4]
	x = 567
	`


    test: map[string]Type
    testing.expect(t, unmarshal_string(test_toml, &test, context.temp_allocator) == .None)
    defer free_all(context.temp_allocator)

    table1 := test["table1"].(^Table)
    table1_x := table1["x"]

    table2 := test["table2"].(^Table)
    table2_x := table2["x"]

    table3 := test["table3"].(^Table)
    table4 := table3["table4"].(^Table)
    table4_x := table4["x"]

    testing.expect_value(t, table1_x, 123)
    testing.expect_value(t, table2_x, 345)
    testing.expect_value(t, table4_x, 567)

}

@(test)
unmarshal_lists_to_struct :: proc(t: ^testing.T) {
    test_toml := `
	slice = [1, 2, 3, 4]
	arr = [1, 2, 3, 4]
	dyn_arr = [1, 2, 3, 4]
	enum_arr = [1, 2, 3, 4]
	`


    Test_Enum :: enum {
        One,
        Two,
        Three,
        Four,
    }

    Test :: struct {
        slice:    []int,
        arr:      [4]int,
        dyn_arr:  [dynamic]int,
        enum_arr: [Test_Enum]int,
    }

    test: Test
    testing.expect(t, unmarshal_string(test_toml, &test, context.temp_allocator) == .None)
    defer free_all(context.temp_allocator)

    expected_arr: []int = {1, 2, 3, 4}

    for i in 0 ..< len(expected_arr) {
        testing.expect_value(t, test.enum_arr[cast(Test_Enum)i], expected_arr[i])
        testing.expect_value(t, test.slice[i], expected_arr[i])
        testing.expect_value(t, test.arr[i], expected_arr[i])
        testing.expect_value(t, test.dyn_arr[i], expected_arr[i])
    }
}

@(test)
unmarshal_lists_to_map :: proc(t: ^testing.T) {
    test_toml := `
	slice = [1, 2, 3, 4]
	arr = [1, 2, 3, 4]
	dyn_arr = [1, 2, 3, 4]
	fixed_dyn_arr = [1, 2, 3, 4]
	enum_arr = [1, 2, 3, 4]
	`


    check_list :: proc(t: ^testing.T, list: []int) {
        expected_arr: []int = {1, 2, 3, 4}
        for i in 0 ..< len(expected_arr) {
            testing.expect_value(t, list[i], expected_arr[i])
        }
    }

    defer free_all(context.temp_allocator)

    test_slice: map[string][]int
    testing.expect(t, unmarshal_string(test_toml, &test_slice, context.temp_allocator) == .None)
    check_list(t, test_slice["slice"])

    test_arr: map[string][4]int
    testing.expect(t, unmarshal_string(test_toml, &test_arr, context.temp_allocator) == .None)
    check_list(t, (&test_arr["arr"])[:])

    test_dynarr: map[string][dynamic]int
    testing.expect(t, unmarshal_string(test_toml, &test_dynarr, context.temp_allocator) == .None)
    check_list(t, test_dynarr["dyn_arr"][:])

    test_fixed_dynarr: map[string][dynamic; 8]int
    testing.expect(t, unmarshal_string(test_toml, &test_fixed_dynarr, context.temp_allocator) == .None)
    check_list(t, (&test_fixed_dynarr["fixed_dyn_arr"])[:])

    Test_Enum :: enum {
        One,
        Two,
        Three,
        Four,
    }
    test_enumarr: map[string][Test_Enum]int
    testing.expect(t, unmarshal_string(test_toml, &test_enumarr, context.temp_allocator) == .None)
    check_list(t, slice.enumerated_array(&test_enumarr["enum_arr"]))
}

@(test)
unmarshal_strings_survive_table_delete :: proc(t: ^testing.T) {
    test_toml := `
	name = "hello"
	tags = ["a", "b"]

	[labels]
	foo = "bar"
	`

    Test :: struct {
        name:   string,
        tags:   [dynamic]string,
        labels: map[string]string,
    }

    table, parse_err := parse(test_toml, "owned-string-test", context.temp_allocator)
    testing.expect(t, parse_err.type == .None)
    defer free_all(context.temp_allocator)

    parsed_name := table["name"].(string)
    parsed_tags := table["tags"].(^List)
    parsed_labels := table["labels"].(^Table)
    parsed_label_value := parsed_labels["foo"].(string)
    parsed_label_key := ""
    for key in parsed_labels {
        parsed_label_key = key
        break
    }

    test: Test
    testing.expect(t, unmarshal_table(&test, table) == .None)
    testing.expectf(t, raw_data(test.name) != raw_data(parsed_name), "struct string should be cloned")
    testing.expectf(t, raw_data(test.tags[0]) != raw_data(parsed_tags[0].(string)), "list string should be cloned")
    testing.expectf(
        t,
        raw_data(test.labels["foo"]) != raw_data(parsed_label_value),
        "map value string should be cloned",
    )

    map_key_cloned := false
    for key in test.labels {
        map_key_cloned = raw_data(key) != raw_data(parsed_label_key)
        break
    }
    testing.expectf(t, map_key_cloned, "map key string should be cloned")

    deep_delete(table, context.temp_allocator)

    testing.expect_value(t, test.name, "hello")
    testing.expect_value(t, test.tags[0], "a")
    testing.expect_value(t, test.tags[1], "b")
    testing.expect_value(t, test.labels["foo"], "bar")
}

@(test)
parse_strings_survive_source_delete :: proc(t: ^testing.T) {
    source := strings.clone(`
	name = "hello"

	[labels]
	foo = "bar"
	`, context.temp_allocator)
    defer free_all(context.temp_allocator)

    table, parse_err := parse(source, "owned-source-test", context.temp_allocator)
    testing.expect(t, parse_err.type == .None)

    parsed_name := table["name"].(string)
    parsed_labels := table["labels"].(^Table)
    parsed_label_value := parsed_labels["foo"].(string)

    hello_idx := strings.index(source, "hello")
    bar_idx := strings.index(source, "bar")
    testing.expect(t, hello_idx >= 0)
    testing.expect(t, bar_idx >= 0)
    testing.expectf(
        t,
        raw_data(parsed_name) != raw_data(source[hello_idx:hello_idx + len("hello")]),
        "parser should own a backing copy independent of caller input",
    )
    testing.expectf(
        t,
        raw_data(parsed_label_value) != raw_data(source[bar_idx:bar_idx + len("bar")]),
        "nested parser strings should not borrow caller input directly",
    )

    delete(source, context.temp_allocator)

    testing.expect_value(t, parsed_name, "hello")
    testing.expect_value(t, parsed_label_value, "bar")
    deep_delete(table, context.temp_allocator)
}

@(test)
unmarshal_enumerated_array_from_table :: proc(t: ^testing.T) {
    // [Enum]T now unmarshals from a TOML table keyed by variant name.
    // Unmentioned variants are left untouched (no zero-fill).
    test_toml := `
	[perks]
	spacious = {chance = 0.7, exclusive = "res"}
	haunted  = {chance = 0.3, exclusive = "res"}
	`

    Perk :: struct {
        chance:    f32,
        exclusive: string,
    }
    Perk_Type :: enum {
        none,
        spacious,
        haunted,
    }

    Test :: struct {
        perks: [Perk_Type]Perk,
    }

    // Seed a non-zero default for `none` and an alternative value for `spacious`
    // so we can prove that the unmarshal path leaves them alone when missing
    // in the TOML (none) or when present (spacious gets overwritten).
    test: Test = {
        perks = {
            .none = {chance = 0.99, exclusive = "should_stay"},
            .spacious = {chance = 0.0, exclusive = ""},
            .haunted = {chance = 0.0, exclusive = ""},
        },
    }
    testing.expect(t, unmarshal_string(test_toml, &test, context.temp_allocator) == .None)
    defer free_all(context.temp_allocator)

    // `none` not in TOML -> unchanged from seed.
    testing.expect_value(t, test.perks[.none].chance, 0.99)
    testing.expect_value(t, test.perks[.none].exclusive, "should_stay")

    // `spacious` and `haunted` present in TOML -> overwritten.
    testing.expect_value(t, test.perks[.spacious].chance, 0.7)
    testing.expect_value(t, test.perks[.spacious].exclusive, "res")
    testing.expect_value(t, test.perks[.haunted].chance, 0.3)
    testing.expect_value(t, test.perks[.haunted].exclusive, "res")
}

@(test)
marshal_enumerated_array_as_table :: proc(t: ^testing.T) {
    Perk :: struct {
        chance:    f32,
        exclusive: string,
    }
    Perk_Type :: enum {
        none,
        spacious,
        haunted,
    }

    Test :: struct {
        perks: [Perk_Type]Perk,
    }

    src: Test = {
        perks = {
            .none = {chance = 0.0, exclusive = ""},
            .spacious = {chance = 0.7, exclusive = "res"},
            .haunted = {chance = 0.3, exclusive = "res"},
        },
    }

    out_table := marshal(&src, context.temp_allocator)
    defer deep_delete(out_table, context.temp_allocator)

    perks_table, ok := out_table["perks"].(^Table)
    testing.expectf(t, ok, "enumerated array must marshal as ^Table, got %T", out_table["perks"])

    // Every declared variant gets its own named key.
    testing.expect(t, "none" in perks_table)
    testing.expect(t, "spacious" in perks_table)
    testing.expect(t, "haunted" in perks_table)

    spacious := perks_table["spacious"].(^Table)
    // The struct holds f32; the TOML value is f64. Compare via the same
    // f32 -> f64 conversion the marshal path uses.
    testing.expect_value(t, spacious["chance"], f64(f32(0.7)))
    testing.expect_value(t, spacious["exclusive"], "res")

    haunted := perks_table["haunted"].(^Table)
    testing.expect_value(t, haunted["chance"], f64(f32(0.3)))
    testing.expect_value(t, haunted["exclusive"], "res")
}

@(test)
enumerated_array_round_trip :: proc(t: ^testing.T) {
    // Marshal then unmarshal must produce an equivalent value.
    Perk :: struct {
        chance:    f32,
        exclusive: string,
    }
    Perk_Type :: enum {
        none,
        spacious,
        haunted,
        historical,
    }

    Wrapper :: struct {
        perks: [Perk_Type]Perk,
    }

    src: Wrapper = {
        perks = {
            .none = {chance = 0.0, exclusive = ""},
            .spacious = {chance = 0.7, exclusive = "res"},
            .haunted = {chance = 0.3, exclusive = "res"},
            .historical = {chance = 0.1, exclusive = ""},
        },
    }

    out_table := marshal(&src, context.temp_allocator)
    defer deep_delete(out_table, context.temp_allocator)

    text := emit(out_table)
    defer delete_string(text)

    dst: Wrapper
    testing.expect(t, unmarshal_string(text, &dst, context.temp_allocator) == .None)
    defer free_all(context.temp_allocator)

    for p in Perk_Type {
        testing.expect_value(t, dst.perks[p].chance, src.perks[p].chance)
        testing.expect_value(t, dst.perks[p].exclusive, src.perks[p].exclusive)
    }
}

@(test)
emit_nested_tables_as_sections :: proc(t: ^testing.T) {
    Test :: struct {
        version: i64,
        outer:   struct {
            text:  string,
            inner: struct {
                value: i64,
            },
        },
    }

    src: Test = {
        version = 1,
        outer = {text = "hi", inner = {value = 2}},
    }

    out_table := marshal(&src, context.temp_allocator)
    defer deep_delete(out_table, context.temp_allocator)

    text := emit(out_table)
    defer delete_string(text)

    testing.expect(t, strings.contains(text, "\"version\" = 1"))
    testing.expect(t, strings.contains(text, "[\"outer\"]"))
    testing.expect(t, strings.contains(text, "[\"outer\".\"inner\"]"))
    testing.expect(t, !strings.contains(text, "\"outer\" = {"))

    dst: Test
    testing.expect(t, unmarshal_string(text, &dst, context.temp_allocator) == .None)
    defer free_all(context.temp_allocator)

    testing.expect_value(t, dst.version, src.version)
    testing.expect_value(t, dst.outer.text, src.outer.text)
    testing.expect_value(t, dst.outer.inner.value, src.outer.inner.value)
}

@(test)
enumerated_array_unmarshal_unknown_keys_ignored :: proc(t: ^testing.T) {
    // Unknown variant names in the TOML must be silently skipped (no error),
    // matching the "missing keys are ignored" behavior for partial configs.
    test_toml := `
	[perks]
	spacious = {chance = 0.7, exclusive = "res"}
	not_a_real_variant = {chance = 0.5, exclusive = "biz"}
	`

    Perk :: struct {
        chance:    f32,
        exclusive: string,
    }
    Perk_Type :: enum {
        none,
        spacious,
    }

    Test :: struct {
        perks: [Perk_Type]Perk,
    }

    test: Test
    err := unmarshal_string(test_toml, &test, context.temp_allocator)
    testing.expect_value(t, err, Unmarshal_Error.None)
    defer free_all(context.temp_allocator)

    testing.expect_value(t, test.perks[.spacious].chance, 0.7)
    testing.expect_value(t, test.perks[.spacious].exclusive, "res")
    // `none` not in TOML -> still zero.
    testing.expect_value(t, test.perks[.none].chance, 0.0)
}
