#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <vector>
#include <node.h>
#include "im.h"

using v8::Array;
using v8::BigInt;
using v8::Boolean;
using v8::Context;
using v8::External;
using v8::FunctionCallbackInfo;
using v8::Isolate;
using v8::Local;
using v8::NewStringType;
using v8::Null;
using v8::Number;
using v8::Object;
using v8::String;
using v8::Value;

static void ThrowError(Isolate* isolate, const char* message) {
    isolate->ThrowException(String::NewFromUtf8(isolate, message, NewStringType::kNormal).ToLocalChecked());
}

template <typename T>
static T* ReadHandle(Local<Value> value) {
    if (value.IsEmpty() || !value->IsExternal()) return nullptr;
    return static_cast<T*>(External::Cast(*value)->Value());
}

static bool ReadU32(Local<Context> ctx, Local<Value> value, uint32_t* out) {
    if (out == nullptr || value.IsEmpty()) return false;
    const auto maybe = value->Uint32Value(ctx);
    if (maybe.IsNothing()) return false;
    *out = maybe.FromJust();
    return true;
}

static bool ReadI32(Local<Context> ctx, Local<Value> value, int32_t* out) {
    if (out == nullptr || value.IsEmpty()) return false;
    const auto maybe = value->Int32Value(ctx);
    if (maybe.IsNothing()) return false;
    *out = maybe.FromJust();
    return true;
}

static bool ReadF64(Local<Context> ctx, Local<Value> value, double* out) {
    if (out == nullptr || value.IsEmpty()) return false;
    const auto maybe = value->NumberValue(ctx);
    if (maybe.IsNothing()) return false;
    *out = maybe.FromJust();
    return true;
}

static bool ReadF32(Local<Context> ctx, Local<Value> value, float* out) {
    if (out == nullptr || value.IsEmpty()) return false;
    const auto maybe = value->NumberValue(ctx);
    if (maybe.IsNothing()) return false;
    *out = static_cast<float>(maybe.FromJust());
    return true;
}

static std::string ReadUtf8OrDefault(Isolate* isolate, Local<Context> ctx, Local<Value> value, const char* fallback) {
    if (value.IsEmpty() || value->IsNullOrUndefined()) return std::string(fallback);
    Local<String> as_string;
    if (!value->ToString(ctx).ToLocal(&as_string)) return std::string(fallback);
    String::Utf8Value utf8(isolate, as_string);
    if (*utf8 == nullptr) return std::string(fallback);
    return std::string(*utf8, static_cast<size_t>(utf8.length()));
}

static bool ReadVec2(Isolate* isolate, Local<Context> ctx, Local<Value> value, ImNodeVec2* out) {
    if (out == nullptr || value.IsEmpty() || !value->IsObject()) return false;

    if (value->IsArray()) {
        auto arr = Local<Array>::Cast(value);
        if (arr->Length() < 2) return false;
        return ReadF32(ctx, arr->Get(ctx, 0).ToLocalChecked(), &out->x) &&
               ReadF32(ctx, arr->Get(ctx, 1).ToLocalChecked(), &out->y);
    }

    Local<Object> obj = value->ToObject(ctx).ToLocalChecked();
    Local<String> x_name = String::NewFromUtf8(isolate, "x", NewStringType::kNormal).ToLocalChecked();
    Local<String> y_name = String::NewFromUtf8(isolate, "y", NewStringType::kNormal).ToLocalChecked();
    if (!obj->Has(ctx, x_name).FromMaybe(false) || !obj->Has(ctx, y_name).FromMaybe(false)) return false;

    return ReadF32(ctx, obj->Get(ctx, x_name).ToLocalChecked(), &out->x) &&
           ReadF32(ctx, obj->Get(ctx, y_name).ToLocalChecked(), &out->y);
}

static bool ReadVec4(Isolate* isolate, Local<Context> ctx, Local<Value> value, float* out4) {
    if (out4 == nullptr || value.IsEmpty() || !value->IsObject()) return false;

    if (value->IsArray()) {
        auto arr = Local<Array>::Cast(value);
        if (arr->Length() < 4) return false;
        return ReadF32(ctx, arr->Get(ctx, 0).ToLocalChecked(), &out4[0]) &&
               ReadF32(ctx, arr->Get(ctx, 1).ToLocalChecked(), &out4[1]) &&
               ReadF32(ctx, arr->Get(ctx, 2).ToLocalChecked(), &out4[2]) &&
               ReadF32(ctx, arr->Get(ctx, 3).ToLocalChecked(), &out4[3]);
    }

    Local<Object> obj = value->ToObject(ctx).ToLocalChecked();
    Local<String> r_name = String::NewFromUtf8(isolate, "r", NewStringType::kNormal).ToLocalChecked();
    Local<String> g_name = String::NewFromUtf8(isolate, "g", NewStringType::kNormal).ToLocalChecked();
    Local<String> b_name = String::NewFromUtf8(isolate, "b", NewStringType::kNormal).ToLocalChecked();
    Local<String> a_name = String::NewFromUtf8(isolate, "a", NewStringType::kNormal).ToLocalChecked();

    if (!obj->Has(ctx, r_name).FromMaybe(false) || !obj->Has(ctx, g_name).FromMaybe(false) ||
        !obj->Has(ctx, b_name).FromMaybe(false) || !obj->Has(ctx, a_name).FromMaybe(false)) {
        return false;
    }

    return ReadF32(ctx, obj->Get(ctx, r_name).ToLocalChecked(), &out4[0]) &&
           ReadF32(ctx, obj->Get(ctx, g_name).ToLocalChecked(), &out4[1]) &&
           ReadF32(ctx, obj->Get(ctx, b_name).ToLocalChecked(), &out4[2]) &&
           ReadF32(ctx, obj->Get(ctx, a_name).ToLocalChecked(), &out4[3]);
}

static Local<Array> MakeVec2Array(Isolate* isolate, Local<Context> ctx, ImNodeVec2 value) {
    Local<Array> arr = Array::New(isolate, 2);
    arr->Set(ctx, 0, Number::New(isolate, value.x)).Check();
    arr->Set(ctx, 1, Number::New(isolate, value.y)).Check();
    return arr;
}

static Local<Array> MakeVec4Array(Isolate* isolate, Local<Context> ctx, float r, float g, float b, float a) {
    Local<Array> arr = Array::New(isolate, 4);
    arr->Set(ctx, 0, Number::New(isolate, r)).Check();
    arr->Set(ctx, 1, Number::New(isolate, g)).Check();
    arr->Set(ctx, 2, Number::New(isolate, b)).Check();
    arr->Set(ctx, 3, Number::New(isolate, a)).Check();
    return arr;
}

static Local<Object> MakeBoolValueResult(Isolate* isolate, Local<Context> ctx, bool changed, bool value) {
    Local<Object> out = Object::New(isolate);
    out->Set(ctx, String::NewFromUtf8(isolate, "changed", NewStringType::kNormal).ToLocalChecked(), Boolean::New(isolate, changed)).Check();
    out->Set(ctx, String::NewFromUtf8(isolate, "value", NewStringType::kNormal).ToLocalChecked(), Boolean::New(isolate, value)).Check();
    return out;
}

static Local<Object> MakeI32ValueResult(Isolate* isolate, Local<Context> ctx, bool changed, int32_t value) {
    Local<Object> out = Object::New(isolate);
    out->Set(ctx, String::NewFromUtf8(isolate, "changed", NewStringType::kNormal).ToLocalChecked(), Boolean::New(isolate, changed)).Check();
    out->Set(ctx, String::NewFromUtf8(isolate, "value", NewStringType::kNormal).ToLocalChecked(), Number::New(isolate, value)).Check();
    return out;
}

static Local<Object> MakeF32ValueResult(Isolate* isolate, Local<Context> ctx, bool changed, float value) {
    Local<Object> out = Object::New(isolate);
    out->Set(ctx, String::NewFromUtf8(isolate, "changed", NewStringType::kNormal).ToLocalChecked(), Boolean::New(isolate, changed)).Check();
    out->Set(ctx, String::NewFromUtf8(isolate, "value", NewStringType::kNormal).ToLocalChecked(), Number::New(isolate, value)).Check();
    return out;
}

static Local<Object> MakeBeginResult(Isolate* isolate, Local<Context> ctx, bool visible, bool open) {
    Local<Object> out = Object::New(isolate);
    out->Set(ctx, String::NewFromUtf8(isolate, "visible", NewStringType::kNormal).ToLocalChecked(), Boolean::New(isolate, visible)).Check();
    out->Set(ctx, String::NewFromUtf8(isolate, "open", NewStringType::kNormal).ToLocalChecked(), Boolean::New(isolate, open)).Check();
    return out;
}

static uintptr_t ReadPtrLike(Isolate* isolate, Local<Context> ctx, Local<Value> value) {
    if (value.IsEmpty() || value->IsNullOrUndefined()) return 0;

    if (value->IsExternal()) {
        return reinterpret_cast<uintptr_t>(External::Cast(*value)->Value());
    }

    if (value->IsBigInt()) {
        bool lossless = false;
        uint64_t out = Local<BigInt>::Cast(value)->Uint64Value(&lossless);
        (void)lossless;
        return static_cast<uintptr_t>(out);
    }

    uint32_t as_u32 = 0;
    if (ReadU32(ctx, value, &as_u32)) {
        return static_cast<uintptr_t>(as_u32);
    }

    double as_f64 = 0.0;
    if (ReadF64(ctx, value, &as_f64)) {
        if (as_f64 < 0) return 0;
        return static_cast<uintptr_t>(as_f64);
    }

    (void)isolate;
    return 0;
}

static bool ReadStringArray(Isolate* isolate, Local<Context> ctx, Local<Value> value, std::vector<std::string>* storage, std::vector<char*>* ptrs) {
    if (storage == nullptr || ptrs == nullptr || value.IsEmpty() || !value->IsArray()) return false;
    auto arr = Local<Array>::Cast(value);
    storage->clear();
    ptrs->clear();
    storage->reserve(arr->Length());
    ptrs->reserve(arr->Length());

    for (uint32_t i = 0; i < arr->Length(); ++i) {
        std::string item = ReadUtf8OrDefault(isolate, ctx, arr->Get(ctx, i).ToLocalChecked(), "");
        storage->push_back(item);
    }

    for (auto& item : *storage) {
        ptrs->push_back(const_cast<char*>(item.c_str()));
    }

    return true;
}

static bool ReadFloatArray(Local<Context> ctx, Local<Value> value, std::vector<float>* out) {
    if (out == nullptr || value.IsEmpty() || !value->IsArray()) return false;
    auto arr = Local<Array>::Cast(value);
    out->clear();
    out->reserve(arr->Length());
    for (uint32_t i = 0; i < arr->Length(); ++i) {
        float v = 0.0f;
        if (!ReadF32(ctx, arr->Get(ctx, i).ToLocalChecked(), &v)) return false;
        out->push_back(v);
    }
    return true;
}

static bool ReadPointsArray(Isolate* isolate, Local<Context> ctx, Local<Value> value, std::vector<ImNodeVec2>* out) {
    if (out == nullptr || value.IsEmpty() || !value->IsArray()) return false;
    auto arr = Local<Array>::Cast(value);
    out->clear();
    out->reserve(arr->Length());

    for (uint32_t i = 0; i < arr->Length(); ++i) {
        ImNodeVec2 point = {};
        if (!ReadVec2(isolate, ctx, arr->Get(ctx, i).ToLocalChecked(), &point)) return false;
        out->push_back(point);
    }

    return true;
}

static void SetNumberProp(Isolate* isolate, Local<Context> ctx, Local<Object> obj, const char* name, double value) {
    obj->Set(ctx, String::NewFromUtf8(isolate, name, NewStringType::kNormal).ToLocalChecked(), Number::New(isolate, value)).Check();
}

static void SetFlagProp(Isolate* isolate, Local<Context> ctx, Local<Object> obj, const char* name, uint32_t bit_index) {
    SetNumberProp(isolate, ctx, obj, name, static_cast<double>(1u << bit_index));
}

static Local<Object> BuildKeyObject(Isolate* isolate, Local<Context> ctx) {
    Local<Object> key = Object::New(isolate);

    SetNumberProp(isolate, ctx, key, "none", 0);
    SetNumberProp(isolate, ctx, key, "named_key_begin", 512);

    const char* named_keys[] = {
        "tab",
        "left_arrow",
        "right_arrow",
        "up_arrow",
        "down_arrow",
        "page_up",
        "page_down",
        "home",
        "end",
        "insert",
        "delete",
        "backspace",
        "space",
        "enter",
        "escape",
        "left_ctrl",
        "left_shift",
        "left_alt",
        "left_super",
        "right_ctrl",
        "right_shift",
        "right_alt",
        "right_super",
        "menu",
        "_0",
        "_1",
        "_2",
        "_3",
        "_4",
        "_5",
        "_6",
        "_7",
        "_8",
        "_9",
        "a",
        "b",
        "c",
        "d",
        "e",
        "f",
        "g",
        "h",
        "i",
        "j",
        "k",
        "l",
        "m",
        "n",
        "o",
        "p",
        "q",
        "r",
        "s",
        "t",
        "u",
        "v",
        "w",
        "x",
        "y",
        "z",
        "f1",
        "f2",
        "f3",
        "f4",
        "f5",
        "f6",
        "f7",
        "f8",
        "f9",
        "f10",
        "f11",
        "f12",
        "f13",
        "f14",
        "f15",
        "f16",
        "f17",
        "f18",
        "f19",
        "f20",
        "f21",
        "f22",
        "f23",
        "f24",
        "apostrophe",
        "comma",
        "minus",
        "period",
        "slash",
        "semicolon",
        "equal",
        "left_bracket",
        "backslash",
        "right_bracket",
        "grave_accent",
        "caps_lock",
        "scroll_lock",
        "num_lock",
        "print_screen",
        "pause",
        "keypad_0",
        "keypad_1",
        "keypad_2",
        "keypad_3",
        "keypad_4",
        "keypad_5",
        "keypad_6",
        "keypad_7",
        "keypad_8",
        "keypad_9",
        "keypad_decimal",
        "keypad_divide",
        "keypad_multiply",
        "keypad_subtract",
        "keypad_add",
        "keypad_enter",
        "keypad_equal",
        "app_back",
        "app_forward",
        "oem102",
        "gamepad_start",
        "gamepad_back",
        "gamepad_face_left",
        "gamepad_face_right",
        "gamepad_face_up",
        "gamepad_face_down",
        "gamepad_dpad_left",
        "gamepad_dpad_right",
        "gamepad_dpad_up",
        "gamepad_dpad_down",
        "gamepad_l1",
        "gamepad_r1",
        "gamepad_l2",
        "gamepad_r2",
        "gamepad_l3",
        "gamepad_r3",
        "gamepad_l_stick_left",
        "gamepad_l_stick_right",
        "gamepad_l_stick_up",
        "gamepad_l_stick_down",
        "gamepad_r_stick_left",
        "gamepad_r_stick_right",
        "gamepad_r_stick_up",
        "gamepad_r_stick_down",
        "mouse_left",
        "mouse_right",
        "mouse_middle",
        "mouse_x1",
        "mouse_x2",
        "mouse_wheel_x",
        "mouse_wheel_y",
        "reserved_for_mod_ctrl",
        "reserved_for_mod_shift",
        "reserved_for_mod_alt",
        "reserved_for_mod_super",
    };

    uint32_t key_value = 512;
    for (const char* name : named_keys) {
        SetNumberProp(isolate, ctx, key, name, static_cast<double>(key_value));
        ++key_value;
    }

    SetNumberProp(isolate, ctx, key, "named_key_end", static_cast<double>(key_value - 1));
    SetNumberProp(isolate, ctx, key, "named_key_count", static_cast<double>(sizeof(named_keys) / sizeof(named_keys[0])));

    SetNumberProp(isolate, ctx, key, "imgui_mod_none", 0);
    SetNumberProp(isolate, ctx, key, "imgui_mod_ctrl", 4096);
    SetNumberProp(isolate, ctx, key, "imgui_mod_shift", 8192);
    SetNumberProp(isolate, ctx, key, "imgui_mod_alt", 16384);
    SetNumberProp(isolate, ctx, key, "imgui_mod_super", 32768);
    SetNumberProp(isolate, ctx, key, "imgui_mod_mask", 61440);

    SetNumberProp(isolate, ctx, key, "count", 667);
    SetNumberProp(isolate, ctx, key, "mod_ctrl", 4096);
    SetNumberProp(isolate, ctx, key, "mod_shift", 8192);
    SetNumberProp(isolate, ctx, key, "mod_alt", 16384);
    SetNumberProp(isolate, ctx, key, "mod_super", 32768);
    SetNumberProp(isolate, ctx, key, "mod_shortcut", 4096);

    return key;
}

static void CheckVersion(const FunctionCallbackInfo<Value>& args) {
    (void)args;
    __im_check_version();
}

static void FreeTmpAlloc(const FunctionCallbackInfo<Value>& args) {
    (void)args;
    im_free_tmp_alloc();
}

static void CreateContext(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    void* ctx = __im_create_context();
    if (ctx == nullptr) {
        args.GetReturnValue().Set(Null(isolate));
        return;
    }
    args.GetReturnValue().Set(External::New(isolate, ctx));
}

static void DestroyContext(const FunctionCallbackInfo<Value>& args) {
    void* ctx = args.Length() >= 1 ? ReadHandle<void>(args[0]) : nullptr;
    __im_destroy_context(ctx);
}

static void GetCurrentContext(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    void* ctx = __im_get_current_context();
    if (ctx == nullptr) {
        args.GetReturnValue().Set(Null(isolate));
        return;
    }
    args.GetReturnValue().Set(External::New(isolate, ctx));
}

static void SetCurrentContext(const FunctionCallbackInfo<Value>& args) {
    void* ctx = args.Length() >= 1 ? ReadHandle<void>(args[0]) : nullptr;
    __im_set_current_context(ctx);
}

static void GetIO(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    void* io = __im_get_io();
    if (io == nullptr) {
        args.GetReturnValue().Set(Null(isolate));
        return;
    }
    args.GetReturnValue().Set(External::New(isolate, io));
}

static void NewFrame(const FunctionCallbackInfo<Value>& args) {
    (void)args;
    __im_new_frame();
}

static void EndFrame(const FunctionCallbackInfo<Value>& args) {
    (void)args;
    __im_end_frame();
}

static void Render(const FunctionCallbackInfo<Value>& args) {
    (void)args;
    __im_render();
}

static void StyleColorsDark(const FunctionCallbackInfo<Value>& args) {
    (void)args;
    __im_style_colors_dark();
}

static void StyleColorsLight(const FunctionCallbackInfo<Value>& args) {
    (void)args;
    __im_style_colors_light();
}

static void StyleColorsClassic(const FunctionCallbackInfo<Value>& args) {
    (void)args;
    __im_style_colors_classic();
}

static void ShowDemoWindow(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    bool use_open = false;
    bool open = true;
    if (args.Length() >= 1 && !args[0]->IsNullOrUndefined()) {
        use_open = true;
        open = args[0]->BooleanValue(isolate);
    }

    ImNodeBoolResult result = __im_show_demo_window(use_open, open);
    args.GetReturnValue().Set(MakeBoolValueResult(isolate, ctx, result.changed, result.value));
}

static void IOAddKeyEvent(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    void* io = args.Length() >= 1 ? ReadHandle<void>(args[0]) : nullptr;
    int32_t key = 0;
    bool down = false;
    if (args.Length() >= 2) ReadI32(ctx, args[1], &key);
    if (args.Length() >= 3) down = args[2]->BooleanValue(isolate);

    __im_io_add_key_event(io, key, down);
}

static void IOAddMousePosEvent(const FunctionCallbackInfo<Value>& args) {
    Local<Context> ctx = args.GetIsolate()->GetCurrentContext();

    void* io = args.Length() >= 1 ? ReadHandle<void>(args[0]) : nullptr;
    float x = 0.0f;
    float y = 0.0f;
    if (args.Length() >= 2) ReadF32(ctx, args[1], &x);
    if (args.Length() >= 3) ReadF32(ctx, args[2], &y);

    __im_io_add_mouse_pos_event(io, x, y);
}

static void IOAddMouseButtonEvent(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    void* io = args.Length() >= 1 ? ReadHandle<void>(args[0]) : nullptr;
    int32_t button = 0;
    bool down = false;
    if (args.Length() >= 2) ReadI32(ctx, args[1], &button);
    if (args.Length() >= 3) down = args[2]->BooleanValue(isolate);

    __im_io_add_mouse_button_event(io, button, down);
}

static void IOAddMouseWheelEvent(const FunctionCallbackInfo<Value>& args) {
    Local<Context> ctx = args.GetIsolate()->GetCurrentContext();

    void* io = args.Length() >= 1 ? ReadHandle<void>(args[0]) : nullptr;
    float wheel_x = 0.0f;
    float wheel_y = 0.0f;
    if (args.Length() >= 2) ReadF32(ctx, args[1], &wheel_x);
    if (args.Length() >= 3) ReadF32(ctx, args[2], &wheel_y);

    __im_io_add_mouse_wheel_event(io, wheel_x, wheel_y);
}

static void IOAddInputCharactersUTF8(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    void* io = args.Length() >= 1 ? ReadHandle<void>(args[0]) : nullptr;
    std::string text = "";
    if (args.Length() >= 2) {
        text = ReadUtf8OrDefault(isolate, ctx, args[1], "");
    }

    __im_io_add_input_characters_utf8(io, const_cast<char*>(text.c_str()));
}

static void IOSetDisplaySize(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    void* io = args.Length() >= 1 ? ReadHandle<void>(args[0]) : nullptr;
    ImNodeVec2 size = {0.0f, 0.0f};
    if (args.Length() >= 2) {
        ReadVec2(isolate, ctx, args[1], &size);
    }

    __im_io_set_display_size(io, size);
}

static void Begin(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    std::string name = "window";
    if (args.Length() >= 1) {
        name = ReadUtf8OrDefault(isolate, ctx, args[0], "window");
    }

    bool use_open = false;
    bool open = true;
    if (args.Length() >= 2 && !args[1]->IsNullOrUndefined()) {
        use_open = true;
        open = args[1]->BooleanValue(isolate);
    }

    uint32_t flags = 0;
    if (args.Length() >= 3) ReadU32(ctx, args[2], &flags);

    ImNodeBeginResult result = __im_begin(const_cast<char*>(name.c_str()), use_open, open, flags);
    args.GetReturnValue().Set(MakeBeginResult(isolate, ctx, result.visible, result.open));
}

static void End(const FunctionCallbackInfo<Value>& args) {
    (void)args;
    __im_end();
}

static void BeginChild(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    std::string name = "child";
    if (args.Length() >= 1) {
        name = ReadUtf8OrDefault(isolate, ctx, args[0], "child");
    }

    ImNodeVec2 size = {0.0f, 0.0f};
    if (args.Length() >= 2) {
        ReadVec2(isolate, ctx, args[1], &size);
    }

    uint32_t child_flags = 0;
    uint32_t window_flags = 0;
    if (args.Length() >= 3) ReadU32(ctx, args[2], &child_flags);
    if (args.Length() >= 4) ReadU32(ctx, args[3], &window_flags);

    args.GetReturnValue().Set(__im_begin_child(const_cast<char*>(name.c_str()), size, child_flags, window_flags));
}

static void EndChild(const FunctionCallbackInfo<Value>& args) {
    (void)args;
    __im_end_child();
}

static void Text(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();
    std::string text = "";
    if (args.Length() >= 1) {
        text = ReadUtf8OrDefault(isolate, ctx, args[0], "");
    }
    __im_text(const_cast<char*>(text.c_str()));
}

static void TextUnformatted(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();
    std::string text = "";
    if (args.Length() >= 1) {
        text = ReadUtf8OrDefault(isolate, ctx, args[0], "");
    }
    __im_text_unformatted(const_cast<char*>(text.c_str()));
}

static void TextDisabled(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();
    std::string text = "";
    if (args.Length() >= 1) {
        text = ReadUtf8OrDefault(isolate, ctx, args[0], "");
    }
    __im_text_disabled(const_cast<char*>(text.c_str()));
}

static void SeparatorText(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();
    std::string text = "";
    if (args.Length() >= 1) {
        text = ReadUtf8OrDefault(isolate, ctx, args[0], "");
    }
    __im_separator_text(const_cast<char*>(text.c_str()));
}

static void SameLine(const FunctionCallbackInfo<Value>& args) {
    Local<Context> ctx = args.GetIsolate()->GetCurrentContext();
    float offset = 0.0f;
    float spacing = -1.0f;
    if (args.Length() >= 1) ReadF32(ctx, args[0], &offset);
    if (args.Length() >= 2) ReadF32(ctx, args[1], &spacing);
    __im_same_line(offset, spacing);
}

static void Button(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    std::string label = "button";
    if (args.Length() >= 1) {
        label = ReadUtf8OrDefault(isolate, ctx, args[0], "button");
    }

    ImNodeVec2 size = {0.0f, 0.0f};
    if (args.Length() >= 2) {
        ReadVec2(isolate, ctx, args[1], &size);
    }

    args.GetReturnValue().Set(__im_button(const_cast<char*>(label.c_str()), size));
}

static void SmallButton(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    std::string label = "button";
    if (args.Length() >= 1) {
        label = ReadUtf8OrDefault(isolate, ctx, args[0], "button");
    }

    args.GetReturnValue().Set(__im_small_button(const_cast<char*>(label.c_str())));
}

static void Checkbox(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    std::string label = "checkbox";
    if (args.Length() >= 1) {
        label = ReadUtf8OrDefault(isolate, ctx, args[0], "checkbox");
    }

    bool value = false;
    if (args.Length() >= 2) value = args[1]->BooleanValue(isolate);

    ImNodeBoolResult result = __im_checkbox(const_cast<char*>(label.c_str()), value);
    args.GetReturnValue().Set(MakeBoolValueResult(isolate, ctx, result.changed, result.value));
}

static void SliderFloat(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    std::string label = "slider_float";
    if (args.Length() >= 1) {
        label = ReadUtf8OrDefault(isolate, ctx, args[0], "slider_float");
    }

    float value = 0.0f;
    float v_min = 0.0f;
    float v_max = 1.0f;
    if (args.Length() >= 2) ReadF32(ctx, args[1], &value);
    if (args.Length() >= 3) ReadF32(ctx, args[2], &v_min);
    if (args.Length() >= 4) ReadF32(ctx, args[3], &v_max);

    std::string format_storage;
    char* format = nullptr;
    if (args.Length() >= 5 && !args[4]->IsNullOrUndefined()) {
        format_storage = ReadUtf8OrDefault(isolate, ctx, args[4], "%.3f");
        format = const_cast<char*>(format_storage.c_str());
    }

    uint32_t flags = 0;
    if (args.Length() >= 6) ReadU32(ctx, args[5], &flags);

    ImNodeF32Result result = __im_slider_float(const_cast<char*>(label.c_str()), value, v_min, v_max, format, flags);
    args.GetReturnValue().Set(MakeF32ValueResult(isolate, ctx, result.changed, result.value));
}

static void SliderInt(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    std::string label = "slider_int";
    if (args.Length() >= 1) {
        label = ReadUtf8OrDefault(isolate, ctx, args[0], "slider_int");
    }

    int32_t value = 0;
    int32_t v_min = 0;
    int32_t v_max = 100;
    if (args.Length() >= 2) ReadI32(ctx, args[1], &value);
    if (args.Length() >= 3) ReadI32(ctx, args[2], &v_min);
    if (args.Length() >= 4) ReadI32(ctx, args[3], &v_max);

    std::string format_storage;
    char* format = nullptr;
    if (args.Length() >= 5 && !args[4]->IsNullOrUndefined()) {
        format_storage = ReadUtf8OrDefault(isolate, ctx, args[4], "%d");
        format = const_cast<char*>(format_storage.c_str());
    }

    uint32_t flags = 0;
    if (args.Length() >= 6) ReadU32(ctx, args[5], &flags);

    ImNodeI32Result result = __im_slider_int(const_cast<char*>(label.c_str()), value, v_min, v_max, format, flags);
    args.GetReturnValue().Set(MakeI32ValueResult(isolate, ctx, result.changed, result.value));
}

static void DragFloat(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    std::string label = "drag_float";
    if (args.Length() >= 1) {
        label = ReadUtf8OrDefault(isolate, ctx, args[0], "drag_float");
    }

    float value = 0.0f;
    float speed = 1.0f;
    float v_min = 0.0f;
    float v_max = 0.0f;
    if (args.Length() >= 2) ReadF32(ctx, args[1], &value);
    if (args.Length() >= 3) ReadF32(ctx, args[2], &speed);
    if (args.Length() >= 4) ReadF32(ctx, args[3], &v_min);
    if (args.Length() >= 5) ReadF32(ctx, args[4], &v_max);

    std::string format_storage;
    char* format = nullptr;
    if (args.Length() >= 6 && !args[5]->IsNullOrUndefined()) {
        format_storage = ReadUtf8OrDefault(isolate, ctx, args[5], "%.3f");
        format = const_cast<char*>(format_storage.c_str());
    }

    uint32_t flags = 0;
    if (args.Length() >= 7) ReadU32(ctx, args[6], &flags);

    ImNodeF32Result result = __im_drag_float(const_cast<char*>(label.c_str()), value, speed, v_min, v_max, format, flags);
    args.GetReturnValue().Set(MakeF32ValueResult(isolate, ctx, result.changed, result.value));
}

static void DragInt(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    std::string label = "drag_int";
    if (args.Length() >= 1) {
        label = ReadUtf8OrDefault(isolate, ctx, args[0], "drag_int");
    }

    int32_t value = 0;
    float speed = 1.0f;
    int32_t v_min = 0;
    int32_t v_max = 0;
    if (args.Length() >= 2) ReadI32(ctx, args[1], &value);
    if (args.Length() >= 3) ReadF32(ctx, args[2], &speed);
    if (args.Length() >= 4) ReadI32(ctx, args[3], &v_min);
    if (args.Length() >= 5) ReadI32(ctx, args[4], &v_max);

    std::string format_storage;
    char* format = nullptr;
    if (args.Length() >= 6 && !args[5]->IsNullOrUndefined()) {
        format_storage = ReadUtf8OrDefault(isolate, ctx, args[5], "%d");
        format = const_cast<char*>(format_storage.c_str());
    }

    uint32_t flags = 0;
    if (args.Length() >= 7) ReadU32(ctx, args[6], &flags);

    ImNodeI32Result result = __im_drag_int(const_cast<char*>(label.c_str()), value, speed, v_min, v_max, format, flags);
    args.GetReturnValue().Set(MakeI32ValueResult(isolate, ctx, result.changed, result.value));
}

static void ComboChar(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    std::string label = "combo";
    if (args.Length() >= 1) {
        label = ReadUtf8OrDefault(isolate, ctx, args[0], "combo");
    }

    int32_t current = 0;
    if (args.Length() >= 2) ReadI32(ctx, args[1], &current);

    std::vector<std::string> item_storage;
    std::vector<char*> item_ptrs;
    if (args.Length() < 3 || !ReadStringArray(isolate, ctx, args[2], &item_storage, &item_ptrs)) {
        ThrowError(isolate, "combo_char expects items string array");
        return;
    }

    int32_t max_items = -1;
    if (args.Length() >= 4) ReadI32(ctx, args[3], &max_items);

    ImNodeI32Result result = __im_combo_char(
        const_cast<char*>(label.c_str()),
        current,
        item_ptrs.empty() ? nullptr : item_ptrs.data(),
        static_cast<int32_t>(item_ptrs.size()),
        max_items
    );

    args.GetReturnValue().Set(MakeI32ValueResult(isolate, ctx, result.changed, result.value));
}

static void ColorEdit4(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    std::string label = "color";
    if (args.Length() >= 1) {
        label = ReadUtf8OrDefault(isolate, ctx, args[0], "color");
    }

    float color[4] = {1.0f, 1.0f, 1.0f, 1.0f};
    if (args.Length() >= 2) {
        ReadVec4(isolate, ctx, args[1], color);
    }

    uint32_t flags = 0;
    if (args.Length() >= 3) ReadU32(ctx, args[2], &flags);

    ImNodeColor4Result result = __im_color_edit4(
        const_cast<char*>(label.c_str()),
        color[0],
        color[1],
        color[2],
        color[3],
        flags
    );

    Local<Object> out = Object::New(isolate);
    out->Set(ctx, String::NewFromUtf8(isolate, "changed", NewStringType::kNormal).ToLocalChecked(), Boolean::New(isolate, result.changed)).Check();
    out->Set(ctx, String::NewFromUtf8(isolate, "value", NewStringType::kNormal).ToLocalChecked(), MakeVec4Array(isolate, ctx, result.r, result.g, result.b, result.a)).Check();
    args.GetReturnValue().Set(out);
}

static void ProgressBar(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    float fraction = 0.0f;
    if (args.Length() >= 1) ReadF32(ctx, args[0], &fraction);

    ImNodeVec2 size = {0.0f, 0.0f};
    if (args.Length() >= 2) {
        ReadVec2(isolate, ctx, args[1], &size);
    }

    std::string overlay_storage;
    char* overlay = nullptr;
    if (args.Length() >= 3 && !args[2]->IsNullOrUndefined()) {
        overlay_storage = ReadUtf8OrDefault(isolate, ctx, args[2], "");
        overlay = const_cast<char*>(overlay_storage.c_str());
    }

    __im_progress_bar(fraction, size, overlay);
}

static void PlotLines(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    std::string label = "plot";
    if (args.Length() >= 1) {
        label = ReadUtf8OrDefault(isolate, ctx, args[0], "plot");
    }

    std::vector<float> values;
    if (args.Length() < 2 || !ReadFloatArray(ctx, args[1], &values)) {
        ThrowError(isolate, "plot_lines expects numeric array");
        return;
    }

    int32_t values_offset = 0;
    if (args.Length() >= 3) ReadI32(ctx, args[2], &values_offset);

    std::string overlay_storage;
    char* overlay = nullptr;
    if (args.Length() >= 4 && !args[3]->IsNullOrUndefined()) {
        overlay_storage = ReadUtf8OrDefault(isolate, ctx, args[3], "");
        overlay = const_cast<char*>(overlay_storage.c_str());
    }

    float scale_min = std::numeric_limits<float>::max();
    float scale_max = std::numeric_limits<float>::max();
    if (args.Length() >= 5) ReadF32(ctx, args[4], &scale_min);
    if (args.Length() >= 6) ReadF32(ctx, args[5], &scale_max);

    ImNodeVec2 graph_size = {0.0f, 0.0f};
    if (args.Length() >= 7) ReadVec2(isolate, ctx, args[6], &graph_size);

    int32_t stride = static_cast<int32_t>(sizeof(float));
    if (args.Length() >= 8) ReadI32(ctx, args[7], &stride);

    __im_plot_lines(
        const_cast<char*>(label.c_str()),
        values.empty() ? nullptr : values.data(),
        static_cast<int32_t>(values.size()),
        values_offset,
        overlay,
        scale_min,
        scale_max,
        graph_size,
        stride
    );
}

static void SetScrollHereY(const FunctionCallbackInfo<Value>& args) {
    Local<Context> ctx = args.GetIsolate()->GetCurrentContext();
    float ratio = 0.5f;
    if (args.Length() >= 1) ReadF32(ctx, args[0], &ratio);
    __im_set_scroll_here_y(ratio);
}

static void PushID(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();
    std::string value = "";
    if (args.Length() >= 1) {
        value = ReadUtf8OrDefault(isolate, ctx, args[0], "");
    }
    __im_push_id(const_cast<char*>(value.c_str()));
}

static void PushIDPtr(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();
    uintptr_t value = 0;
    if (args.Length() >= 1) {
        value = ReadPtrLike(isolate, ctx, args[0]);
    }
    __im_push_id_ptr(value);
}

static void PopID(const FunctionCallbackInfo<Value>& args) {
    (void)args;
    __im_pop_id();
}

static void BeginDisabled(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    bool disabled = true;
    if (args.Length() >= 1) {
        disabled = args[0]->BooleanValue(isolate);
    }
    __im_begin_disabled(disabled);
}

static void EndDisabled(const FunctionCallbackInfo<Value>& args) {
    (void)args;
    __im_end_disabled();
}

static void Curve(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    std::string label = "curve";
    if (args.Length() >= 1) {
        label = ReadUtf8OrDefault(isolate, ctx, args[0], "curve");
    }

    ImNodeVec2 size = {0.0f, 0.0f};
    if (args.Length() >= 2) {
        ReadVec2(isolate, ctx, args[1], &size);
    }

    std::vector<ImNodeVec2> points;
    if (args.Length() < 3 || !ReadPointsArray(isolate, ctx, args[2], &points)) {
        ThrowError(isolate, "curve expects points array");
        return;
    }

    bool use_selection = false;
    int32_t selection = 0;
    if (args.Length() >= 4 && !args[3]->IsNullOrUndefined()) {
        use_selection = true;
        ReadI32(ctx, args[3], &selection);
    }

    ImNodeVec2 range_min = {0.0f, 0.0f};
    ImNodeVec2 range_max = {1.0f, 1.0f};
    if (args.Length() >= 5) ReadVec2(isolate, ctx, args[4], &range_min);
    if (args.Length() >= 6) ReadVec2(isolate, ctx, args[5], &range_max);

    ImNodeSelectionResult result = __im_curve(
        const_cast<char*>(label.c_str()),
        size,
        static_cast<int32_t>(points.size()),
        points.empty() ? nullptr : points.data(),
        use_selection,
        selection,
        range_min,
        range_max
    );

    Local<Array> point_values = Array::New(isolate, points.size());
    for (uint32_t i = 0; i < points.size(); ++i) {
        point_values->Set(ctx, i, MakeVec2Array(isolate, ctx, points[i])).Check();
    }

    Local<Object> out = Object::New(isolate);
    out->Set(ctx, String::NewFromUtf8(isolate, "changed", NewStringType::kNormal).ToLocalChecked(), Boolean::New(isolate, result.changed)).Check();
    out->Set(ctx, String::NewFromUtf8(isolate, "selection", NewStringType::kNormal).ToLocalChecked(), Number::New(isolate, result.selection)).Check();
    out->Set(ctx, String::NewFromUtf8(isolate, "points", NewStringType::kNormal).ToLocalChecked(), point_values).Check();
    args.GetReturnValue().Set(out);
}

static void CurveValue(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    float p = 0.0f;
    if (args.Length() >= 1) ReadF32(ctx, args[0], &p);

    std::vector<ImNodeVec2> points;
    if (args.Length() < 2 || !ReadPointsArray(isolate, ctx, args[1], &points)) {
        ThrowError(isolate, "curve_value expects points array");
        return;
    }

    args.GetReturnValue().Set(__im_curve_value(p, static_cast<int32_t>(points.size()), points.empty() ? nullptr : points.data()));
}

static void CurveValueSmooth(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    float p = 0.0f;
    if (args.Length() >= 1) ReadF32(ctx, args[0], &p);

    std::vector<ImNodeVec2> points;
    if (args.Length() < 2 || !ReadPointsArray(isolate, ctx, args[1], &points)) {
        ThrowError(isolate, "curve_value_smooth expects points array");
        return;
    }

    args.GetReturnValue().Set(__im_curve_value_smooth(p, static_cast<int32_t>(points.size()), points.empty() ? nullptr : points.data()));
}

void Initialize(Local<Object> exports) {
    Isolate* isolate = exports->GetIsolate();
    Local<Context> ctx = isolate->GetCurrentContext();

    im_set_odin_ctx();

    NODE_SET_METHOD(exports, "free_tmp_alloc", FreeTmpAlloc);

    NODE_SET_METHOD(exports, "check_version", CheckVersion);
    NODE_SET_METHOD(exports, "create_context", CreateContext);
    NODE_SET_METHOD(exports, "destroy_context", DestroyContext);
    NODE_SET_METHOD(exports, "get_current_context", GetCurrentContext);
    NODE_SET_METHOD(exports, "set_current_context", SetCurrentContext);
    NODE_SET_METHOD(exports, "get_io", GetIO);
    NODE_SET_METHOD(exports, "new_frame", NewFrame);
    NODE_SET_METHOD(exports, "end_frame", EndFrame);
    NODE_SET_METHOD(exports, "render", Render);
    NODE_SET_METHOD(exports, "style_colors_dark", StyleColorsDark);
    NODE_SET_METHOD(exports, "style_colors_light", StyleColorsLight);
    NODE_SET_METHOD(exports, "style_colors_classic", StyleColorsClassic);
    NODE_SET_METHOD(exports, "show_demo_window", ShowDemoWindow);

    NODE_SET_METHOD(exports, "io_add_key_event", IOAddKeyEvent);
    NODE_SET_METHOD(exports, "io_add_mouse_pos_event", IOAddMousePosEvent);
    NODE_SET_METHOD(exports, "io_add_mouse_button_event", IOAddMouseButtonEvent);
    NODE_SET_METHOD(exports, "io_add_mouse_wheel_event", IOAddMouseWheelEvent);
    NODE_SET_METHOD(exports, "io_add_input_characters_utf8", IOAddInputCharactersUTF8);
    NODE_SET_METHOD(exports, "io_set_display_size", IOSetDisplaySize);

    NODE_SET_METHOD(exports, "begin", Begin);
    NODE_SET_METHOD(exports, "end", End);
    NODE_SET_METHOD(exports, "begin_child", BeginChild);
    NODE_SET_METHOD(exports, "end_child", EndChild);
    NODE_SET_METHOD(exports, "text", Text);
    NODE_SET_METHOD(exports, "text_unformatted", TextUnformatted);
    NODE_SET_METHOD(exports, "text_disabled", TextDisabled);
    NODE_SET_METHOD(exports, "separator_text", SeparatorText);
    NODE_SET_METHOD(exports, "same_line", SameLine);
    NODE_SET_METHOD(exports, "button", Button);
    NODE_SET_METHOD(exports, "small_button", SmallButton);
    NODE_SET_METHOD(exports, "checkbox", Checkbox);
    NODE_SET_METHOD(exports, "slider_float", SliderFloat);
    NODE_SET_METHOD(exports, "slider_int", SliderInt);
    NODE_SET_METHOD(exports, "drag_float", DragFloat);
    NODE_SET_METHOD(exports, "drag_int", DragInt);
    NODE_SET_METHOD(exports, "combo_char", ComboChar);
    NODE_SET_METHOD(exports, "color_edit4", ColorEdit4);
    NODE_SET_METHOD(exports, "progress_bar", ProgressBar);
    NODE_SET_METHOD(exports, "plot_lines", PlotLines);
    NODE_SET_METHOD(exports, "set_scroll_here_y", SetScrollHereY);
    NODE_SET_METHOD(exports, "push_id", PushID);
    NODE_SET_METHOD(exports, "push_id_ptr", PushIDPtr);
    NODE_SET_METHOD(exports, "pop_id", PopID);
    NODE_SET_METHOD(exports, "begin_disabled", BeginDisabled);
    NODE_SET_METHOD(exports, "end_disabled", EndDisabled);
    NODE_SET_METHOD(exports, "curve", Curve);
    NODE_SET_METHOD(exports, "curve_value", CurveValue);
    NODE_SET_METHOD(exports, "curve_value_smooth", CurveValueSmooth);

    Local<Object> key = BuildKeyObject(isolate, ctx);

    Local<Object> mouse_button = Object::New(isolate);
    SetNumberProp(isolate, ctx, mouse_button, "left", 0);
    SetNumberProp(isolate, ctx, mouse_button, "right", 1);
    SetNumberProp(isolate, ctx, mouse_button, "middle", 2);
    SetNumberProp(isolate, ctx, mouse_button, "count", 5);

    Local<Object> cond = Object::New(isolate);
    SetNumberProp(isolate, ctx, cond, "none", 0);
    SetNumberProp(isolate, ctx, cond, "always", 1);
    SetNumberProp(isolate, ctx, cond, "once", 2);
    SetNumberProp(isolate, ctx, cond, "first_use_ever", 4);
    SetNumberProp(isolate, ctx, cond, "appearing", 8);

    Local<Object> window_flag = Object::New(isolate);
    SetFlagProp(isolate, ctx, window_flag, "no_title_bar", 0);
    SetFlagProp(isolate, ctx, window_flag, "no_resize", 1);
    SetFlagProp(isolate, ctx, window_flag, "no_move", 2);
    SetFlagProp(isolate, ctx, window_flag, "no_scrollbar", 3);
    SetFlagProp(isolate, ctx, window_flag, "no_scroll_with_mouse", 4);
    SetFlagProp(isolate, ctx, window_flag, "no_collapse", 5);
    SetFlagProp(isolate, ctx, window_flag, "always_auto_resize", 6);
    SetFlagProp(isolate, ctx, window_flag, "no_background", 7);
    SetFlagProp(isolate, ctx, window_flag, "no_saved_settings", 8);
    SetFlagProp(isolate, ctx, window_flag, "no_mouse_inputs", 9);
    SetFlagProp(isolate, ctx, window_flag, "menu_bar", 10);
    SetFlagProp(isolate, ctx, window_flag, "horizontal_scrollbar", 11);
    SetFlagProp(isolate, ctx, window_flag, "no_focus_on_appearing", 12);
    SetFlagProp(isolate, ctx, window_flag, "no_bring_to_front_on_focus", 13);
    SetFlagProp(isolate, ctx, window_flag, "always_vertical_scrollbar", 14);
    SetFlagProp(isolate, ctx, window_flag, "always_horizontal_scrollbar", 15);
    SetFlagProp(isolate, ctx, window_flag, "no_nav_inputs", 16);
    SetFlagProp(isolate, ctx, window_flag, "no_nav_focus", 17);
    SetFlagProp(isolate, ctx, window_flag, "unsaved_document", 18);
    SetFlagProp(isolate, ctx, window_flag, "child_window", 24);
    SetFlagProp(isolate, ctx, window_flag, "tooltip", 25);
    SetFlagProp(isolate, ctx, window_flag, "popup", 26);
    SetFlagProp(isolate, ctx, window_flag, "modal", 27);
    SetFlagProp(isolate, ctx, window_flag, "child_menu", 28);
    SetFlagProp(isolate, ctx, window_flag, "nav_flattened", 29);
    SetFlagProp(isolate, ctx, window_flag, "always_use_window_padding", 30);
    SetNumberProp(isolate, ctx, window_flag, "no_nav", static_cast<double>((1u << 16) | (1u << 17)));
    SetNumberProp(isolate, ctx, window_flag, "no_decoration", static_cast<double>((1u << 0) | (1u << 1) | (1u << 3) | (1u << 5)));
    SetNumberProp(isolate, ctx, window_flag, "no_inputs", static_cast<double>((1u << 9) | (1u << 16) | (1u << 17)));

    Local<Object> child_flag = Object::New(isolate);
    SetFlagProp(isolate, ctx, child_flag, "borders", 0);
    SetFlagProp(isolate, ctx, child_flag, "always_use_window_padding", 1);
    SetFlagProp(isolate, ctx, child_flag, "resize_x", 2);
    SetFlagProp(isolate, ctx, child_flag, "resize_y", 3);
    SetFlagProp(isolate, ctx, child_flag, "auto_resize_x", 4);
    SetFlagProp(isolate, ctx, child_flag, "auto_resize_y", 5);
    SetFlagProp(isolate, ctx, child_flag, "always_auto_resize", 6);
    SetFlagProp(isolate, ctx, child_flag, "frame_style", 7);
    SetFlagProp(isolate, ctx, child_flag, "nav_flattened", 8);
    SetNumberProp(isolate, ctx, child_flag, "border", static_cast<double>(1u << 0));

    Local<Object> slider_flag = Object::New(isolate);
    SetFlagProp(isolate, ctx, slider_flag, "logarithmic", 5);
    SetFlagProp(isolate, ctx, slider_flag, "no_round_to_format", 6);
    SetFlagProp(isolate, ctx, slider_flag, "no_input", 7);
    SetFlagProp(isolate, ctx, slider_flag, "wrap_around", 8);
    SetFlagProp(isolate, ctx, slider_flag, "clamp_on_input", 9);
    SetFlagProp(isolate, ctx, slider_flag, "clamp_zero_range", 10);
    SetFlagProp(isolate, ctx, slider_flag, "no_speed_tweaks", 11);
    SetNumberProp(isolate, ctx, slider_flag, "always_clamp", static_cast<double>((1u << 9) | (1u << 10)));

    Local<Object> color_edit_flag = Object::New(isolate);
    SetFlagProp(isolate, ctx, color_edit_flag, "no_alpha", 1);
    SetFlagProp(isolate, ctx, color_edit_flag, "no_picker", 2);
    SetFlagProp(isolate, ctx, color_edit_flag, "no_options", 3);
    SetFlagProp(isolate, ctx, color_edit_flag, "no_small_preview", 4);
    SetFlagProp(isolate, ctx, color_edit_flag, "no_inputs", 5);
    SetFlagProp(isolate, ctx, color_edit_flag, "no_tooltip", 6);
    SetFlagProp(isolate, ctx, color_edit_flag, "no_label", 7);
    SetFlagProp(isolate, ctx, color_edit_flag, "no_side_preview", 8);
    SetFlagProp(isolate, ctx, color_edit_flag, "no_drag_drop", 9);
    SetFlagProp(isolate, ctx, color_edit_flag, "no_border", 10);
    SetFlagProp(isolate, ctx, color_edit_flag, "alpha_opaque", 11);
    SetFlagProp(isolate, ctx, color_edit_flag, "alpha_no_bg", 12);
    SetFlagProp(isolate, ctx, color_edit_flag, "alpha_preview_half", 13);
    SetFlagProp(isolate, ctx, color_edit_flag, "alpha_bar", 16);
    SetFlagProp(isolate, ctx, color_edit_flag, "hdr", 19);
    SetFlagProp(isolate, ctx, color_edit_flag, "display_rgb", 20);
    SetFlagProp(isolate, ctx, color_edit_flag, "display_hsv", 21);
    SetFlagProp(isolate, ctx, color_edit_flag, "display_hex", 22);
    SetFlagProp(isolate, ctx, color_edit_flag, "uint8", 23);
    SetFlagProp(isolate, ctx, color_edit_flag, "float", 24);
    SetFlagProp(isolate, ctx, color_edit_flag, "picker_hue_bar", 25);
    SetFlagProp(isolate, ctx, color_edit_flag, "picker_hue_wheel", 26);
    SetFlagProp(isolate, ctx, color_edit_flag, "input_rgb", 27);
    SetFlagProp(isolate, ctx, color_edit_flag, "input_hsv", 28);

    exports->Set(ctx, String::NewFromUtf8(isolate, "Key", NewStringType::kNormal).ToLocalChecked(), key).Check();
    exports->Set(ctx, String::NewFromUtf8(isolate, "MouseButton", NewStringType::kNormal).ToLocalChecked(), mouse_button).Check();
    exports->Set(ctx, String::NewFromUtf8(isolate, "Cond", NewStringType::kNormal).ToLocalChecked(), cond).Check();
    exports->Set(ctx, String::NewFromUtf8(isolate, "WindowFlag", NewStringType::kNormal).ToLocalChecked(), window_flag).Check();
    exports->Set(ctx, String::NewFromUtf8(isolate, "ChildFlag", NewStringType::kNormal).ToLocalChecked(), child_flag).Check();
    exports->Set(ctx, String::NewFromUtf8(isolate, "SliderFlag", NewStringType::kNormal).ToLocalChecked(), slider_flag).Check();
    exports->Set(ctx, String::NewFromUtf8(isolate, "ColorEditFlag", NewStringType::kNormal).ToLocalChecked(), color_edit_flag).Check();
}

NODE_MODULE(NODE_GYP_MODULE_NAME, Initialize)
