export namespace Im {
  type OpaqueHandle<T extends string> = { readonly __imHandle?: T }
  type ImContext = OpaqueHandle<'ImContext'>
  type ImIO = OpaqueHandle<'ImIO'>

  type vec2 = [number, number]
  type vec4 = [number, number, number, number]

  type BoolValueResult = { changed: boolean, value: boolean }
  type IntValueResult = { changed: boolean, value: number }
  type FloatValueResult = { changed: boolean, value: number }
  type BeginResult = { visible: boolean, open: boolean }
  type CurveResult = { changed: boolean, selection: number, points: vec2[] }
}

export const im: {
  Key: Record<string, number>,
  MouseButton: Record<string, number>,
  Cond: Record<string, number>,
  WindowFlag: Record<string, number>,
  ChildFlag: Record<string, number>,
  SliderFlag: Record<string, number>,
  ColorEditFlag: Record<string, number>,

  free_tmp_alloc(): void,

  check_version(): void,
  create_context(): Im.ImContext | null,
  destroy_context(ctx: Im.ImContext | null): void,
  get_current_context(): Im.ImContext | null,
  set_current_context(ctx: Im.ImContext | null): void,
  get_io(): Im.ImIO | null,

  new_frame(): void,
  end_frame(): void,
  render(): void,
  style_colors_dark(): void,
  style_colors_light(): void,
  style_colors_classic(): void,
  show_demo_window(open?: boolean | null): Im.BoolValueResult,

  io_add_key_event(io: Im.ImIO, key: number, down: boolean): void,
  io_add_mouse_pos_event(io: Im.ImIO, x: number, y: number): void,
  io_add_mouse_button_event(io: Im.ImIO, button: number, down: boolean): void,
  io_add_mouse_wheel_event(io: Im.ImIO, wheelX: number, wheelY: number): void,
  io_add_input_characters_utf8(io: Im.ImIO, text: string): void,
  io_set_display_size(io: Im.ImIO, size: Im.vec2): void,

  begin(name: string, open?: boolean | null, windowFlags?: number): Im.BeginResult,
  end(): void,
  begin_child(strId: string, size?: Im.vec2, childFlags?: number, windowFlags?: number): boolean,
  end_child(): void,

  text(value: string): void,
  text_unformatted(value: string): void,
  text_disabled(value: string): void,
  separator_text(value: string): void,
  same_line(offsetFromStartX?: number, spacing?: number): void,

  button(label: string, size?: Im.vec2): boolean,
  small_button(label: string): boolean,
  checkbox(label: string, value: boolean): Im.BoolValueResult,

  slider_float(label: string, value: number, min: number, max: number, format?: string | null, flags?: number): Im.FloatValueResult,
  slider_int(label: string, value: number, min: number, max: number, format?: string | null, flags?: number): Im.IntValueResult,
  drag_float(label: string, value: number, speed?: number, min?: number, max?: number, format?: string | null, flags?: number): Im.FloatValueResult,
  drag_int(label: string, value: number, speed?: number, min?: number, max?: number, format?: string | null, flags?: number): Im.IntValueResult,
  combo_char(label: string, currentItem: number, items: string[], popupMaxHeightInItems?: number): Im.IntValueResult,
  color_edit4(label: string, value: Im.vec4, flags?: number): { changed: boolean, value: Im.vec4 },

  progress_bar(fraction: number, size?: Im.vec2, overlay?: string | null): void,
  plot_lines(label: string, values: number[], valuesOffset?: number, overlayText?: string | null, scaleMin?: number, scaleMax?: number, graphSize?: Im.vec2, stride?: number): void,

  set_scroll_here_y(centerYRatio?: number): void,
  push_id(value: string): void,
  push_id_ptr(value: number | bigint | object | null): void,
  pop_id(): void,
  begin_disabled(disabled?: boolean): void,
  end_disabled(): void,

  curve(label: string, size: Im.vec2, points: Im.vec2[], selection?: number | null, rangeMin?: Im.vec2, rangeMax?: Im.vec2): Im.CurveResult,
  curve_value(p: number, points: Im.vec2[]): number,
  curve_value_smooth(p: number, points: Im.vec2[]): number,
}

export = im
