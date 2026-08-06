#pragma once

// @CONFIGURE:
// This file can be filled with config lines in the same way as imconfig.h!
// These will be used in compilation, and will be written into the bindings
// However this support is _VERY VERY_ early and will probably go kablooey!

// Keep backend symbols in C linkage for Odin foreign imports.
#ifndef IMGUI_IMPL_API
    #if defined(__cplusplus)
        #define IMGUI_IMPL_API extern "C"
    #else
        #define IMGUI_IMPL_API
    #endif
#endif

// Enable explicit exports when building the Windows DLL variant.
#if defined(_WIN32) && defined(IMGUI_BUILD_DLL)
    #ifndef CIMGUI_API
        #define CIMGUI_API __declspec(dllexport)
    #endif

    #undef IMGUI_API
    #define IMGUI_API __declspec(dllexport)

    #undef IMGUI_IMPL_API
    #if defined(__cplusplus)
        #define IMGUI_IMPL_API extern "C" __declspec(dllexport)
    #else
        #define IMGUI_IMPL_API __declspec(dllexport)
    #endif
#endif
