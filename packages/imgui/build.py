#!/usr/bin/env python

import argparse
import os
import platform
import random
import shutil
import subprocess
import sys
import typing
from glob import glob
from os import path

# TODO:
# - Make this file never show it's call stack. Call stacks should mean that a child script failed.
# - Add self-documenting build.ini or similar, as to not require anyone to look
# at this file unless they want to add a new backend.
# - It could be nice to be able to generate into another folder, or just say --copy-into../../my_cool_folder

# @CONFIGURE: Must be key into below table
# Note that the backend files and examples may also have to be updated, if you use these.
git_heads = {
    "imgui": "v1.91.9",
    "dear_bindings": "9160500c29f6a87159a852a94f4d2f14173f5e62",
}

# Note - tested with Odin version `dev-2025-07`

# @CONFIGURE: Elements must be keys into below table
wanted_backends = [
    "vulkan",
    # "sdl2",
    "sdl3",
    "opengl3",
    # "sdlrenderer2",
    # "glfw",
    "dx11",
    # "dx12",
    # "win32",
    # "osx",
    "metal",
    # "wgpu",
]
# Supported means that an impl bindings file exists, and that it has been tested.
# Some backends (like dx12, win32) have bindings but not been tested.
backends = {
    # "allegro5": {"supported": False},
    # "android": {"supported": False},
    # "dx9": {"supported": False, "enabled_on": ["windows"]},
    # "dx10": {"supported": False, "enabled_on": ["windows"]},
    "dx11": {"supported": True, "enabled_on": ["windows"]},
    # Bindings exist for DX12, but they are untested
    # "dx12": {"supported": False, "enabled_on": ["windows"]},
    # "glfw": {"supported": True, "deps": ["glfw"]},
    # "glut": {"supported": False},
    "metal": {"supported": True, "enabled_on": ["darwin"]},
    # "opengl2": {"supported": False},
    "opengl3": {"supported": True},
    # "osx": {"supported": True, "enabled_on": ["darwin"]},
    # "sdl2": {"supported": True, "deps": ["sdl2"]},
    "sdl3": {
        "supported": True,
        # "defines": ["IMGUI_IMPL_VULKAN_HAS_DYNAMIC_RENDERING"],
        "deps": ["sdl3"],
    },
    # "sdlrenderer2": {"supported": True, "deps": ["sdl2"]},
    # "sdlrenderer3": {"supported": False},
    "vulkan": {
        "supported": True,
        "defines": [
            "VK_NO_PROTOTYPES",
            "IMGUI_IMPL_VULKAN_HAS_DYNAMIC_RENDERING",
            # "IMGUI_IMPL_VULKAN_USE_LOADER",
            # "IMGUI_IMPL_jULKAN_USE_VOLK",
        ],
        "deps": ["vulkan"],
    },
    # "wgpu": {
    #     "supported": True,
    #     "defines": ["IMGUI_IMPL_WEBGPU_BACKEND_WGPU"],
    #     "deps": ["wgpu"],
    # },
    # Bindings exist for win32, but they are untested
    # "win32": {"supported": False, "enabled_on": ["windows"]},
}

# Indirection for backend dependencies, as some might have the same dependency, and their commits can't get out of sync.
backend_deps = {
    "sdl2": {
        "repo": "https://github.com/libsdl-org/SDL.git",
        "commit": "release-2.32.6",
        "path": "SDL2",
    },
    "sdl3": {
        "repo": "https://github.com/libsdl-org/SDL.git",
        "commit": "release-3.2.14",
        "path": "SDL3",
    },
    "glfw": {
        "repo": "https://github.com/glfw/glfw.git",
        "commit": "3eaf125",
        "path": "glfw",
    },
    "vulkan": {
        "repo": "https://github.com/KhronosGroup/Vulkan-Headers.git",
        "commit": "4f51aac",
        "path": "Vulkan-Headers",
    },
    "wgpu": {
        "repo": "https://github.com/webgpu-native/webgpu-headers.git",
        "commit": "aef5e42",
        "path": "webgpu-headers/webgpu",
        "include": "webgpu-headers",
    },
}

# @CONFIGURE:
compile_debug = False

# @CONFIGURE:
build_wasm = False

# @CONFIGURE:
build_imgui_internal = True

platform_win32_like = platform.system() == "Windows"
platform_unix_like = platform.system() == "Linux" or platform.system() == "Darwin"


# Assert which doesn't clutter the output
def assertx(cond: bool, msg: str):
    if not cond:
        print(msg)
        exit(1)


def hashes_are_same_ish(first: str, second: str) -> bool:
    smallest_hash_size = min(len(first), len(second))
    assertx(smallest_hash_size >= 7, "Hashes not long enough to be sure")
    return first[:smallest_hash_size] == second[:smallest_hash_size]


def exec(cmd: typing.List[str], what: str) -> str:
    max_what_len = 40
    if len(what) > max_what_len:
        what = what[: max_what_len - 2] + ".."
    print(what + (" " * (max_what_len - len(what))) + "> " + " ".join(cmd))
    try:
        return subprocess.check_output(cmd).decode("utf-8")
    except subprocess.CalledProcessError as uh_oh:
        print("=" * 80)
        print("FAILED")
        print("=" * 80)
        print(uh_oh.output.decode())
        exit(1)


def exec_vcvars(cmd: typing.List[str], what):
    max_what_len = 40
    if len(what) > max_what_len:
        what = what[: max_what_len - 2] + ".."
    print(what + (" " * (max_what_len - len(what))) + "> " + " ".join(cmd))
    try:
        return subprocess.check_output(cmd, stderr=subprocess.STDOUT).decode("utf-8")
    except subprocess.CalledProcessError as uh_oh:
        print("=" * 80)
        print("FAILED")
        print("=" * 80)
        print(uh_oh.output.decode())
        exit(1)


def uv_run_cmd(cmd: typing.List[str], requirements: str) -> typing.List[str]:
    uv_bin = resolve_tool(["uv"])
    assertx(
        uv_bin is not None,
        "uv not found! install uv to run dear_bindings requirements.",
    )
    return [uv_bin, "run", "--with-requirements", requirements, *cmd]


def copy(from_path: str, files: typing.List[str], to_path: str):
    for file in files:
        shutil.copy(path.join(from_path, file), to_path)


# glob copy backported for python 3.9
def glob_copy_39(root_dir: str, glob_pattern: str, dest_dir: str):
    real_pattern = os.path.join(root_dir, glob_pattern)
    the_files = glob(real_pattern)

    # strip root_dir
    results = []
    for item in the_files:
        results.append(item[len(root_dir) + 1 :])

    copy(root_dir, results, dest_dir)
    return results


def glob_copy(root_dir: str, glob_pattern: str, dest_dir: str):
    version_info = sys.version_info
    if version_info.major == 3 and version_info.minor == 9:
        return glob_copy_39(root_dir, glob_pattern, dest_dir)

    the_files = glob(root_dir=root_dir, pathname=glob_pattern)
    copy(root_dir, the_files, dest_dir)
    return the_files


def platform_select(the_options):
    """Given a dict like eg. { "windows": "/DCOOL_DEFINE", "linux, darwin": "-DCOOL_DEFINE" }
    Returns the correct value for the active platform."""
    our_platform = platform.system().lower()
    for platforms_string in the_options:
        if platforms_string.lower().find(our_platform) != -1:
            return the_options[platforms_string]

    print(the_options)
    assertx(
        False, f"Couldn't find active platform ({our_platform}) in the above options!"
    )


def pp(the_path: str) -> str:
    """Get Platform Path. Given a path with '/' as a delimiter, returns an appropriate sys.platform path"""
    return path.join(*the_path.split("/"))


def map_to_folder(files: typing.List[str], folder: str) -> typing.List[str]:
    return list(map(lambda file: path.join(folder, file), files))


def has_tool(tool: str) -> bool:
    try:
        subprocess.check_output([tool], stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        return False
    except:
        return True
    else:
        return True


def resolve_tool(candidates: typing.List[str]) -> typing.Optional[str]:
    for candidate in candidates:
        if "/" in candidate or "\\" in candidate:
            if path.isfile(candidate):
                return candidate
            continue

        resolved = shutil.which(candidate)
        if resolved is not None:
            return resolved
    return None


def ensure_checked_out_with_commit(
    dir: str, repo: str, wanted_commit: str, skip_sync: bool = False
):
    if not path.exists(dir):
        assertx(
            not skip_sync,
            f"Repository '{dir}' is missing and -skip-sync was set. Run once without -skip-sync to clone it.",
        )
        exec(
            ["git", "-c", "core.fsmonitor=false", "clone", repo, dir],
            f"Cloning {dir}",
        )

    if skip_sync:
        print(f"Skipping sync for {dir} (-skip-sync)")
    else:
        fetch_cmd = ["git", "-c", "core.fsmonitor=false", "-C", dir, "fetch"]
        max_what_len = 40
        what = f"Fetching latest commits for {dir}"
        if len(what) > max_what_len:
            what = what[: max_what_len - 2] + ".."
        print(what + (" " * (max_what_len - len(what))) + "> " + " ".join(fetch_cmd))
        fetch = subprocess.run(fetch_cmd, capture_output=True, text=True)
        if fetch.returncode != 0:
            print(
                f"Warning: fetch failed for {dir}, continuing with local checkout:\n"
                + ((fetch.stderr or fetch.stdout).strip())
            )

    exec(
        [
            "git",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "advice.detachedHead=false",
            "-C",
            dir,
            "checkout",
            "--force",
            wanted_commit,
        ],
        f"Checking out {dir}",
    )


def get_platform_imgui_lib_name() -> str:
    """Returns imgui binary name for system/processor"""
    system = platform.system()
    arch_dir = get_platform_arch_dir()

    assertx(system != "", "System could not be determined")
    if system == "Windows":
        return path.join(arch_dir, "imgui.lib")
    if system == "Darwin":
        return path.join(arch_dir, "imgui.darwin.a")
    return path.join(arch_dir, "imgui.linux.a")


def get_platform_processor() -> str:
    machine = platform.machine().lower()
    if machine in ["amd64", "x86_64"]:
        return "x64"
    if machine in ["arm64", "aarch64"]:
        return "arm64"
    assertx(False, f"Unexpected processor: {platform.machine()}")
    return ""


def get_platform_arch_dir() -> str:
    system = platform.system()
    processor = get_platform_processor()

    if system == "Windows":
        return f"windows_{processor}"
    if system == "Darwin":
        return f"darwin_{processor}"
    assertx(system == "Linux", f"Unexpected system: {system}")
    return f"linux_{processor}"


def get_platform_imgui_dll_name() -> str:
    """Returns imgui shared library name for system/processor"""
    system = platform.system()
    arch_dir = get_platform_arch_dir()

    if system == "Windows":
        return path.join(arch_dir, "imgui.dll")
    if system == "Darwin":
        return path.join(arch_dir, "imgui.dylib")
    assertx(system == "Linux", f"Unexpected system: {system}")
    return path.join(arch_dir, "imgui.so")


def get_platform_imgui_dll_import_lib_name() -> str:
    """Returns the import library name used by the shared library build."""
    system = platform.system()
    assertx(system == "Windows", "Import library naming is only used on Windows")
    return path.join(get_platform_arch_dir(), "imgui_dll.lib")


def get_sdl_link_dirs(dep: str) -> typing.List[str]:
    sdl_dir = path.abspath(path.join("..", "sdl"))
    system = platform.system()
    processor = get_platform_processor()
    dirs: typing.List[str] = []

    if dep == "sdl3":
        if system == "Windows":
            dirs.append(path.join(sdl_dir, f"windows_{processor}"))
        if system == "Linux":
            dirs.append(path.join(sdl_dir, f"linux_{processor}"))
        dirs += [
            path.join(sdl_dir, "libs", "SDL"),
            path.join(sdl_dir, "build", "SDL"),
            sdl_dir,
        ]
    elif dep == "sdl2":
        dirs += [
            path.join(sdl_dir, "libs", "SDL"),
            path.join(sdl_dir, "build", "SDL"),
            sdl_dir,
        ]
    else:
        return []

    out = []
    seen = set()
    for candidate in dirs:
        resolved = path.abspath(candidate)
        if resolved in seen:
            continue
        seen.add(resolved)
        if path.isdir(resolved):
            out.append(resolved)
    return out


def link_dll():
    """Link a shared library from the .o files in temp/"""
    dll_name = get_platform_imgui_dll_name()
    system = platform.system()
    dll_dir = path.dirname(dll_name)
    if dll_dir:
        os.makedirs(dll_dir, exist_ok=True)

    # Collect extra link flags from backend dependencies.
    extra_link_flags = []
    windows_libpaths = set()
    windows_libs = set()
    enabled_backends = []
    windows_implib_name = None

    for backend_name in wanted_backends:
        backend = backends[backend_name]
        if "enabled_on" in backend and not system.lower() in backend["enabled_on"]:
            continue
        enabled_backends.append(backend_name)
        for dep in backend.get("deps", []):
            if dep == "sdl3":
                if system == "Windows":
                    sdl_link_dirs = get_sdl_link_dirs(dep)
                    for sdl_link_dir in sdl_link_dirs:
                        windows_libpaths.add(sdl_link_dir)
                    if any(
                        path.isfile(path.join(sdl_link_dir, "SDL3.lib"))
                        for sdl_link_dir in sdl_link_dirs
                    ):
                        windows_libs.add("SDL3.lib")
                    elif any(
                        path.isfile(path.join(sdl_link_dir, "SDL3_static.lib"))
                        for sdl_link_dir in sdl_link_dirs
                    ):
                        windows_libs.add("SDL3_static.lib")
                    else:
                        windows_libs.add("SDL3.lib")
                else:
                    for sdl_link_dir in get_sdl_link_dirs(dep):
                        extra_link_flags += ["-L" + sdl_link_dir]
                    extra_link_flags += ["-lSDL3"]
            elif dep == "sdl2":
                if system == "Windows":
                    sdl_dir = path.abspath(path.join("..", "sdl"))
                    windows_libpaths.add(sdl_dir)
                    windows_libs.add("SDL2.lib")
                else:
                    for sdl_link_dir in get_sdl_link_dirs(dep):
                        extra_link_flags += ["-L" + sdl_link_dir]
                    extra_link_flags += ["-lSDL2"]

    # Backends can require extra system SDK libs when producing a DLL.
    if system == "Windows":
        windows_backend_libs = {
            "dx11": ["d3d11.lib", "dxgi.lib"],
            "dx12": ["d3d12.lib", "dxgi.lib", "d3dcompiler.lib"],
            "opengl3": ["opengl32.lib"],
            # Vulkan backend is compiled with VK_NO_PROTOTYPES, so linking the
            # Vulkan loader import library is not required here.
            "vulkan": [],
        }
        for backend_name in enabled_backends:
            for lib_name in windows_backend_libs.get(backend_name, []):
                windows_libs.add(lib_name)

    if system == "Darwin":
        arch = "arm64" if platform.machine() == "arm64" else "x86_64"
        obj_files = glob(path.join("temp", "*.o"))
        exec(
            [
                "/opt/homebrew/opt/llvm/bin/clang++",
                "-dynamiclib",
                "-arch",
                arch,
                "-install_name",
                path.basename(dll_name),
                "-framework",
                "Foundation",
                "-framework",
                "Metal",
                "-framework",
                "QuartzCore",
                "-lc++",
                "-o",
                dll_name,
            ]
            + obj_files
            + extra_link_flags,
            "Linking shared library",
        )
    elif system == "Linux":
        obj_files = glob(path.join("temp", "*.o"))
        exec(
            ["clang++", "-shared", "-o", dll_name]
            + obj_files
            + ["-lstdc++"]
            + extra_link_flags,
            "Linking shared library",
        )
    elif system == "Windows":
        obj_files = glob(path.join("temp", "*.obj"))
        windows_implib_name = get_platform_imgui_dll_import_lib_name()
        link_cmd = [
            "link",
            "/DLL",
            "/OUT:" + dll_name,
            "/IMPLIB:" + windows_implib_name,
        ]
        for libpath in sorted(windows_libpaths):
            link_cmd.append("/LIBPATH:" + libpath)
        link_cmd += obj_files + sorted(windows_libs)
        exec_vcvars(
            link_cmd,
            "Linking shared library",
        )

    assertx(path.isfile(dll_name), f"Failed to create shared library '{dll_name}'")
    print(f"Created shared library: {dll_name}")
    if system == "Windows" and windows_implib_name is not None:
        if path.isfile(windows_implib_name):
            print(f"Created import library: {windows_implib_name}")
        else:
            print(
                "Note: no import library was produced (DLL exports are likely empty)."
            )


# TODO[TS]: This works, but there's a bug in Python, which makes cl.exe return with
# exit code 2 for no god damn reason at all, if not run with run_vcvars.
# If we're on windows, we can check for cl.exe, and re execute after calling vcvarsall, if available.
def did_re_execute(no_reexecute: bool) -> bool:
    if platform.system() != "Windows":
        return False
    if has_tool("cl"):
        return False
    if no_reexecute:
        return False
    print("Re-executing with vcvarsall..")
    forwarded_args = [arg for arg in sys.argv[1:] if arg != "-no_reexecute"]
    rerun_cmd = subprocess.list2cmdline(
        [sys.executable, "build.py", "-no_reexecute"] + forwarded_args
    )
    processor = get_platform_processor()
    result = subprocess.run(
        ["cmd", "/d", "/c", f"call vcvarsall.bat {processor} && {rerun_cmd}"]
    )
    assertx(result.returncode == 0, "Re-executed build failed.")
    return True


def compile(
    backend_deps_names: typing.Set[str],
    base_sources: typing.List[str],
    wasm: bool,
    build_dll: bool = False,
):
    all_sources = list(base_sources)

    # Basic flags
    # We aren't meant to have IMGUI_IMPL_API be extern "C"?
    # https://github.com/ocornut/imgui/issues/7930#issuecomment-2319725332
    if wasm:
        compile_flags = [
            '-DIMGUI_IMPL_API=extern"C"',
            "-DIMGUI_DISABLE_DEFAULT_SHELL_FUNCTIONS",
            "-DIMGUI_DISABLE_FILE_FUNCTIONS",
            "-fno-exceptions",
            "-fno-rtti",
            "-fno-threadsafe-statics",
            "-nostdlib++",
            "-fno-use-cxa-atexit",
            "-std=c++11",
        ]

        # The wasm runtime path needs SDL3 platform backend symbols
        # and OpenGL3 renderer backend symbols.
        if "sdl3" in wanted_backends:
            glob_copy(pp("imgui/backends"), "imgui_impl_sdl3.*", "temp")
            all_sources += ["imgui_impl_sdl3.cpp"]

            # SDL3 headers in this monorepo live next to vendor/imgui.
            for include_path in [
                path.abspath(path.join("..", "sdl", "include")),
                path.abspath(path.join("..", "sdl", "SDL", "include")),
            ]:
                compile_flags += ["-I" + include_path]

        if "opengl3" in wanted_backends:
            compile_flags += ["-DIMGUI_IMPL_OPENGL_ES3"]
            glob_copy(pp("imgui/backends"), "imgui_impl_opengl3.*", "temp")
            if path.isfile(pp("imgui/backends/imgui_impl_opengl3_loader.h")):
                shutil.copy(pp("imgui/backends/imgui_impl_opengl3_loader.h"), "temp")
            all_sources += ["imgui_impl_opengl3.cpp"]
    else:
        compile_flags = platform_select(
            {
                "windows": [],
                "linux, darwin": [
                    '-DIMGUI_IMPL_API=extern"C"',
                    "-fPIC",
                    "-fno-exceptions",
                    "-fno-rtti",
                    "-fno-threadsafe-statics",
                    "-std=c++11",
                ],
            }
        )

    # Optimization flags
    if compile_debug:
        if wasm:
            compile_flags += ["-g", "-O0"]
        else:
            compile_flags += platform_select(
                {"windows": ["/Od", "/Z7"], "linux, darwin": ["-g", "-O0"]}
            )
    elif wasm:
        compile_flags += ["-Os"]
    else:
        compile_flags += platform_select({"windows": ["/O2"], "linux, darwin": ["-O3"]})

    if build_dll and not wasm and platform_win32_like:
        compile_flags += ["/DIMGUI_BUILD_DLL"]

    if not wasm:
        # Find and copy imgui backend sources to temp folder
        for backend_name in wanted_backends:
            backend = backends[backend_name]

            if (
                "enabled_on" in backend
                and not platform.system().lower() in backend["enabled_on"]
            ):
                continue

            if not backend["supported"]:
                print(
                    f"Warning: compiling backend '{backend_name}' which is not officially supported"
                )

            if "odin" in backend and backend["odin"]:
                print(
                    f"Note: backend '{backend_name}' is native Odin code, nothing to compile"
                )
                continue

            glob_copy(pp("imgui/backends"), f"imgui_impl_{backend_name}.*", "temp")

            if backend_name in ["osx", "metal"]:
                all_sources += [f"imgui_impl_{backend_name}.mm"]
                # Copy and compile the C ABI wrapper if it exists
                wrapper = pp(f"impl_{backend_name}/c_imgui_impl_{backend_name}.mm")
                if path.isfile(wrapper):
                    shutil.copy(wrapper, "temp")
                    all_sources += [f"c_imgui_impl_{backend_name}.mm"]
            else:
                all_sources += [f"imgui_impl_{backend_name}.cpp"]

            if backend_name == "opengl3":
                shutil.copy(pp("imgui/backends/imgui_impl_opengl3_loader.h"), "temp")

            for define in backend.get("defines", []):
                compile_flags += [
                    platform_select(
                        {"windows": f"/D{define}", "linux, darwin": f"-D{define}"}
                    )
                ]

        # Add backend dependency include paths
        for backend_dep in backend_deps_names:
            include_path = path.join(backend_deps[backend_dep]["path"], "include")
            if "include" in backend_deps[backend_dep]:
                include_path = backend_deps[backend_dep]["include"]

            if platform_win32_like:
                compile_flags += ["/I" + path.join("..", "backend_deps", include_path)]
            elif platform_unix_like:
                compile_flags += ["-I" + path.join("..", "backend_deps", include_path)]

        # Some wrapper sources include backend headers from ../imgui/backends.
        # Those headers include "imgui.h", which must be found via include search paths.
        if platform_win32_like:
            compile_flags += ["/I" + path.join("..", "imgui")]
        elif platform_unix_like:
            compile_flags += ["-I" + path.join("..", "imgui")]

    all_objects = []
    if wasm:
        for file in all_sources:
            if file.endswith((".cpp", ".mm", ".c")):
                all_objects.append(path.splitext(file)[0] + ".o")
    elif platform_win32_like:
        all_objects += map(lambda file: file.removesuffix(".cpp") + ".obj", all_sources)
    elif platform_unix_like:
        for file in all_sources:
            if file.endswith(".cpp"):
                all_objects.append(file.removesuffix(".cpp") + ".o")
            elif file.endswith(".mm"):
                all_objects.append(file.removesuffix(".mm") + ".o")

    os.chdir("temp")

    if wasm:
        empp = resolve_tool(["em++", "/opt/homebrew/bin/em++"])
        assertx(empp is not None, "em++ not found!")
        exec([empp] + compile_flags + ["-c"] + all_sources, "Compiling sources")
    elif platform_win32_like:
        exec_vcvars(["cl"] + compile_flags + ["/c"] + all_sources, "Compiling sources")
    elif platform.system() == "Darwin":
        clangpp = resolve_tool(["/opt/homebrew/opt/llvm/bin/clang++", "clang++"])
        assertx(clangpp is not None, "clang++ not found!")
        exec(
            [clangpp] + compile_flags + ["-c"] + all_sources,
            "Compiling sources",
        )
    elif platform_unix_like:
        exec(["clang++"] + compile_flags + ["-c"] + all_sources, "Compiling sources")

    os.chdir("..")

    dest_binary = get_platform_imgui_lib_name()
    dest_dir = path.dirname(dest_binary)
    if dest_dir:
        os.makedirs(dest_dir, exist_ok=True)

    if wasm:
        shutil.rmtree(path="wasm", ignore_errors=True)
        os.mkdir("wasm")
        copy("temp", all_objects, "wasm")
        if path.isfile("imgui_wasm.a"):
            os.remove("imgui_wasm.a")
        if platform_win32_like:
            exec(
                ["lib", "/OUT:" + "imgui_wasm.a"] + map_to_folder(all_objects, "wasm"),
                "Making library from objects",
            )
        else:
            ar_tool = resolve_tool(
                [
                    "emar",
                    "/opt/homebrew/bin/emar",
                    "ar",
                    "llvm-ar",
                    "/opt/homebrew/opt/llvm/bin/llvm-ar",
                ]
            )
            assertx(ar_tool is not None, "No archiver found (tried emar/ar/llvm-ar)")
            exec(
                [ar_tool, "rcs", "imgui_wasm.a"] + map_to_folder(all_objects, "wasm"),
                "Making library from objects",
            )
    elif platform_win32_like:
        exec(
            ["lib", "/OUT:" + dest_binary] + map_to_folder(all_objects, "temp"),
            "Making library from objects",
        )
    elif platform_unix_like:
        exec(
            ["ar", "rcs", dest_binary] + map_to_folder(all_objects, "temp"),
            "Making library from objects",
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build and generate bindings for vendor/imgui."
    )
    parser.add_argument(
        "-wasm",
        action="store_true",
        help="Build the WebAssembly static library in addition to native outputs.",
    )
    parser.add_argument(
        "-wasm-only",
        action="store_true",
        help="Only build the WebAssembly static library.",
    )
    parser.add_argument(
        "-skip-sync",
        action="store_true",
        help="Skip git fetch operations for repositories and dependencies.",
    )
    parser.add_argument(
        "-regen-odin",
        action="store_true",
        help="Regenerate Odin bindings with gen_odin.py.",
    )
    parser.add_argument(
        "-dll",
        action="store_true",
        help="Also link a shared library from native build objects.",
    )
    parser.add_argument(
        "-no_reexecute",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    return parser.parse_args()


def main():
    args = parse_args()

    assertx(
        path.isfile("build.py"),
        "You have to run the script from within the repository for now!",
    )

    if did_re_execute(args.no_reexecute):
        return

    do_build_wasm = build_wasm or args.wasm or args.wasm_only
    do_build_native = not args.wasm_only
    skip_sync = args.skip_sync
    regen_odin = args.regen_odin

    assertx(do_build_wasm or do_build_native, "Nothing to build.")

    # Check that CLI tools are available
    assertx(has_tool("git"), "Git not available!")

    if do_build_native:
        if platform.system() == "Windows":
            pass
            # Fun times! We can't check for this, for the reasons described above did_re_execute()
            # assertx(has_tool("cl") and has_tool("lib"), "cl.exe or lib.exe not in path - did you run vcvarsall.bat?")
        else:
            assertx(has_tool("clang"), "clang not found!")
            assertx(has_tool("ar"), "ar not found!")

    if do_build_wasm:
        assertx(
            resolve_tool(["em++", "/opt/homebrew/bin/em++"]) is not None,
            "em++ not found!",
        )
        assertx(
            resolve_tool(
                [
                    "emar",
                    "/opt/homebrew/bin/emar",
                    "ar",
                    "llvm-ar",
                    "/opt/homebrew/opt/llvm/bin/llvm-ar",
                ]
            )
            is not None,
            "No archiver found for wasm build (tried emar/ar/llvm-ar).",
        )

    # Check out bindings generator tools
    ensure_checked_out_with_commit(
        "imgui",
        "https://github.com/ocornut/imgui.git",
        git_heads["imgui"],
        skip_sync=skip_sync,
    )
    # Apply local patches on top of the checked-out imgui commit.
    patches_dir = path.abspath("patches")
    if path.isdir(patches_dir):
        for patch_file in sorted(glob(path.join(patches_dir, "*.patch"))):
            exec(
                [
                    "git",
                    "-c",
                    "core.fsmonitor=false",
                    "-C",
                    "imgui",
                    "am",
                    "--3way",
                    patch_file,
                ],
                f"Applying {path.basename(patch_file)}",
            )
    ensure_checked_out_with_commit(
        "dear_bindings",
        "https://github.com/dearimgui/dear_bindings.git",
        git_heads["dear_bindings"],
        skip_sync=skip_sync,
    )

    backend_deps_names = set()
    if do_build_native:
        # Check out backend dependencies for native backends.
        if not path.isdir("backend_deps"):
            os.mkdir("backend_deps")
        for backend_name in wanted_backends:
            backend = backends[backend_name]

            for dep in backend.get("deps", []):
                backend_deps_names.add(dep)

        for backend_dep in backend_deps_names:
            full_dep = backend_deps[backend_dep]
            ensure_checked_out_with_commit(
                path.join("backend_deps", full_dep["path"]),
                full_dep["repo"],
                full_dep["commit"],
                skip_sync=skip_sync,
            )

    # Clear the temp folder
    shutil.rmtree(path="temp", ignore_errors=True)
    os.mkdir("temp")

    dear_bindings_requirements = pp("dear_bindings/requirements.txt")

    # Generate Odin bindings
    exec(
        uv_run_cmd(
            [
                "python3",
                pp("dear_bindings/dear_bindings.py"),
                "-o",
                pp("temp/c_imgui"),
                "--nogeneratedefaultargfunctions",
                "--imconfig-path",
                pp("imconfig.h"),
                pp("imgui/imgui.h"),
            ],
            dear_bindings_requirements,
        ),
        "Running dear_bindings: ImGui",
    )
    if build_imgui_internal:
        exec(
            uv_run_cmd(
                [
                    "python3",
                    pp("dear_bindings/dear_bindings.py"),
                    "-o",
                    pp("temp/c_imgui_internal"),
                    "--include",
                    pp("imgui/imgui.h"),
                    "--nogeneratedefaultargfunctions",
                    "--imconfig-path",
                    pp("imconfig.h"),
                    pp("imgui/imgui_internal.h"),
                ],
                dear_bindings_requirements,
            ),
            "Running dear_bindings: ImGui Internal",
        )

    # Generate Odin bindings from dear_bindings json file only on demand.
    # Python 3.12+ can produce Odin output with compatibility issues.
    if regen_odin:
        if build_imgui_internal:
            exec(
                [
                    sys.executable,
                    pp("gen_odin.py"),
                    "--imgui",
                    pp("temp/c_imgui.json"),
                    "--imconfig",
                    pp("temp/c_imgui_imconfig.json"),
                    "--imgui_internal",
                    pp("temp/c_imgui_internal.json"),
                ],
                "Running odin-imgui",
            )
        else:
            exec(
                [
                    sys.executable,
                    pp("gen_odin.py"),
                    "--imgui",
                    pp("temp/c_imgui.json"),
                    "--imconfig",
                    pp("temp/c_imgui_imconfig.json"),
                ],
                "Running odin-imgui",
            )
    else:
        print(
            "Skipping odin-imgui generation (use --regen-odin to refresh Odin bindings)."
        )

    # Find and copy imgui sources to temp folder
    _imgui_headers = glob_copy("imgui", "*.h", "temp")
    imgui_sources = glob_copy("imgui", "*.cpp", "temp")
    extra_sources = ["imgui_curve_widget.cpp"]
    copy(".", extra_sources, "temp")

    # We copied `imconfig.h` from imgui, but we have our own. Overwrite the previous one.
    shutil.copy(pp("imconfig.h"), pp("temp/imconfig.h"))

    # Gather sources, defines, includes etc
    all_sources = imgui_sources + extra_sources
    all_sources += ["c_imgui.cpp"]
    if build_imgui_internal:
        all_sources.append("c_imgui_internal.cpp")

    # Write file describing the build configuration.
    f = open("enabled.odin", "w+")
    f.writelines(
        [
            "package imgui\n",
            "\n",
            "// This is a generated helper file which you can use to know about the build configuration.\n",
            "\n",
        ]
    )

    f.writelines([f"DEBUG_ENABLED :: {'true' if compile_debug else 'false'}", "\n"])
    f.writelines(
        [f"WASM_ENABLED :: {'true' if do_build_wasm else 'false'}", "\n", "\n"]
    )

    for backend_name in backends:
        f.writelines(
            [
                f"BACKEND_{backend_name.upper()}_ENABLED :: {'true' if backend_name in wanted_backends else 'false'}\n"
            ]
        )
    f.writelines([f"BACKEND_WEBGL_ENABLED :: {'true' if do_build_wasm else 'false'}\n"])

    if do_build_wasm:
        compile(backend_deps_names, all_sources, True)
    if do_build_native:
        compile(backend_deps_names, all_sources, False, args.dll)

    if do_build_native and args.dll:
        link_dll()

    dest_binary = get_platform_imgui_lib_name()

    expected_files = [
        "imgui.odin",
        "enabled.odin",
    ]  # TODO: imconfig, internal
    if do_build_native:
        expected_files.append(dest_binary)
        if args.dll:
            expected_files.append(get_platform_imgui_dll_name())
            if platform.system() == "Windows":
                expected_files.append(get_platform_imgui_dll_import_lib_name())
    if do_build_wasm:
        expected_files.append("imgui_wasm.a")

    for file in expected_files:
        assertx(
            path.isfile(file),
            f"Missing file '{file}' in build folder! Something went wrong..",
        )

    print("Looks like everything went ok!")
    if random.random() < 0.01:
        print("But looks may deceive..")


if __name__ == "__main__":
    main()
