cmake_minimum_required(VERSION 3.25)
project(OpenLF2 VERSION 1.1.2 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
include("${PROJECT_SOURCE_DIR}/cmake/OpenLF2Icons.cmake")
if(ANDROID)
    # The Android entry point is a shared object and links the project static libraries.
    set(CMAKE_POSITION_INDEPENDENT_CODE ON)
endif()
if(CMAKE_SYSTEM_NAME STREQUAL "NintendoSwitch")
    set(openlf2_default_dependency_provider switch)
elseif(EMSCRIPTEN)
    set(openlf2_default_dependency_provider web)
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(openlf2_default_dependency_provider system)
else()
    set(openlf2_default_dependency_provider conan)
endif()
set(OPENLF2_DEPENDENCY_PROVIDER "${openlf2_default_dependency_provider}" CACHE STRING
    "Library provider: conan, system, switch, vita or web")
set_property(CACHE OPENLF2_DEPENDENCY_PROVIDER PROPERTY STRINGS conan system switch vita web)

# AppImages use Conan 2; local Linux and Debian builds use system development packages.
if(OPENLF2_DEPENDENCY_PROVIDER STREQUAL "conan")
    find_package(SDL3 3.2 CONFIG REQUIRED)
    find_package(LuaJIT CONFIG REQUIRED)
    find_package(ZLIB CONFIG REQUIRED)
    find_package(BZip2 CONFIG REQUIRED)
    find_package(OpenSSL CONFIG REQUIRED)
    find_package(FFmpeg CONFIG REQUIRED)
    set(openlf2_ffmpeg_targets FFmpeg::avformat FFmpeg::avcodec
        FFmpeg::avutil FFmpeg::swresample)
    find_package(CURL CONFIG REQUIRED)
elseif(OPENLF2_DEPENDENCY_PROVIDER STREQUAL "system")
    list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
    find_package(SDL3 3.2 CONFIG REQUIRED)
    find_package(LuaJIT 2.1 REQUIRED)
    find_package(ZLIB 1.2 REQUIRED)
    find_package(BZip2 1.0.8 REQUIRED)
    find_package(OpenSSL 3 REQUIRED COMPONENTS Crypto)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(OPENLF2_FFMPEG REQUIRED IMPORTED_TARGET libavformat>=60
        libavcodec>=60 libavutil>=58 libswresample>=4.10)
    set(openlf2_ffmpeg_targets PkgConfig::OPENLF2_FFMPEG)
    find_package(CURL 7.85 REQUIRED)
elseif(OPENLF2_DEPENDENCY_PROVIDER STREQUAL "web")
    if(NOT EMSCRIPTEN)
        message(FATAL_ERROR "The web provider requires the Emscripten toolchain")
    endif()
    # SDL 3.4 built with Emscripten into the web prefix (dist/web/build-inside.sh), not Emscripten's older bundled port.
    find_package(SDL3 3.4 CONFIG REQUIRED)
    find_package(ZLIB REQUIRED)
    find_package(BZip2 REQUIRED)
    if(NOT OPENLF2_WEB_LUA_ROOT OR NOT OPENLF2_WEB_FFMPEG_ROOT)
        message(FATAL_ERROR "Set OPENLF2_WEB_LUA_ROOT and OPENLF2_WEB_FFMPEG_ROOT")
    endif()
    add_library(LuaJIT::LuaJIT STATIC IMPORTED)
    set_target_properties(LuaJIT::LuaJIT PROPERTIES
        IMPORTED_LOCATION "${OPENLF2_WEB_LUA_ROOT}/src/liblua.a"
        INTERFACE_INCLUDE_DIRECTORIES "${OPENLF2_WEB_LUA_ROOT}/src")
    add_library(openlf2_web_ffmpeg INTERFACE)
    target_include_directories(openlf2_web_ffmpeg SYSTEM INTERFACE "${OPENLF2_WEB_FFMPEG_ROOT}/include")
    target_link_libraries(openlf2_web_ffmpeg INTERFACE
        "${OPENLF2_WEB_FFMPEG_ROOT}/lib/libavformat.a"
        "${OPENLF2_WEB_FFMPEG_ROOT}/lib/libavcodec.a"
        "${OPENLF2_WEB_FFMPEG_ROOT}/lib/libswresample.a"
        "${OPENLF2_WEB_FFMPEG_ROOT}/lib/libavutil.a")
    set(openlf2_ffmpeg_targets openlf2_web_ffmpeg)
elseif(OPENLF2_DEPENDENCY_PROVIDER STREQUAL "vita")
    if(NOT DEFINED VITASDK)
        message(FATAL_ERROR "The vita provider requires the VitaSDK toolchain")
    endif()
    find_package(SDL3 3.2 CONFIG REQUIRED)
    find_package(PkgConfig REQUIRED)
    if(NOT OPENLF2_VITA_LUAJIT_ROOT)
        message(FATAL_ERROR "Set OPENLF2_VITA_LUAJIT_ROOT to the cross-built LuaJIT directory")
    endif()
    add_library(LuaJIT::LuaJIT STATIC IMPORTED)
    set_target_properties(LuaJIT::LuaJIT PROPERTIES
        IMPORTED_LOCATION "${OPENLF2_VITA_LUAJIT_ROOT}/src/libluajit.a"
        INTERFACE_INCLUDE_DIRECTORIES "${OPENLF2_VITA_LUAJIT_ROOT}/src")
    find_package(ZLIB REQUIRED)
    find_package(BZip2 REQUIRED)
    find_package(OpenSSL REQUIRED COMPONENTS Crypto)
    pkg_check_modules(OPENLF2_FFMPEG REQUIRED IMPORTED_TARGET libavformat>=60
        libavcodec>=60 libavutil>=58 libswresample>=4.10)
    set(openlf2_ffmpeg_targets PkgConfig::OPENLF2_FFMPEG)
    pkg_check_modules(OPENLF2_MPG123 REQUIRED IMPORTED_TARGET libmpg123)
    pkg_check_modules(OPENLF2_CURL REQUIRED IMPORTED_TARGET libcurl>=7.85)
    add_library(CURL::libcurl ALIAS PkgConfig::OPENLF2_CURL)
    pkg_check_modules(OPENLF2_MBEDTLS REQUIRED IMPORTED_TARGET mbedtls)
elseif(OPENLF2_DEPENDENCY_PROVIDER STREQUAL "switch")
    if(NOT CMAKE_SYSTEM_NAME STREQUAL "NintendoSwitch")
        message(FATAL_ERROR "The switch provider requires the devkitPro Switch toolchain")
    endif()
    find_package(SDL3 3.4 CONFIG REQUIRED)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(OPENLF2_FFMPEG REQUIRED IMPORTED_TARGET libavformat>=60
        libavcodec>=60 libavutil>=58 libswresample>=4.10)
    set(openlf2_ffmpeg_targets PkgConfig::OPENLF2_FFMPEG)
    pkg_check_modules(OPENLF2_CURL REQUIRED IMPORTED_TARGET libcurl>=7.69)
    add_library(CURL::libcurl ALIAS PkgConfig::OPENLF2_CURL)
    pkg_check_modules(OPENLF2_EGL REQUIRED IMPORTED_TARGET egl)
    find_library(openlf2_zlib NAMES z REQUIRED)
    add_library(ZLIB::ZLIB STATIC IMPORTED)
    set_target_properties(ZLIB::ZLIB PROPERTIES IMPORTED_LOCATION "${openlf2_zlib}"
        INTERFACE_INCLUDE_DIRECTORIES "${DEVKITPRO}/portlibs/switch/include")
    find_library(openlf2_bzip2 NAMES bz2 REQUIRED)
    add_library(BZip2::BZip2 STATIC IMPORTED)
    set_target_properties(BZip2::BZip2 PROPERTIES IMPORTED_LOCATION "${openlf2_bzip2}"
        INTERFACE_INCLUDE_DIRECTORIES "${DEVKITPRO}/portlibs/switch/include")
    find_library(openlf2_mbedcrypto NAMES mbedcrypto REQUIRED)
    add_library(openlf2_mbedcrypto_target STATIC IMPORTED)
    set_target_properties(openlf2_mbedcrypto_target PROPERTIES
        IMPORTED_LOCATION "${openlf2_mbedcrypto}"
        INTERFACE_INCLUDE_DIRECTORIES "${DEVKITPRO}/portlibs/switch/include")
    if(NOT OPENLF2_SWITCH_LUAJIT_ROOT)
        message(FATAL_ERROR "Set OPENLF2_SWITCH_LUAJIT_ROOT to the cross-built LuaJIT directory")
    endif()
    add_library(LuaJIT::LuaJIT STATIC IMPORTED)
    set_target_properties(LuaJIT::LuaJIT PROPERTIES
        IMPORTED_LOCATION "${OPENLF2_SWITCH_LUAJIT_ROOT}/src/libluajit.a"
        INTERFACE_INCLUDE_DIRECTORIES "${OPENLF2_SWITCH_LUAJIT_ROOT}/src")
else()
    message(FATAL_ERROR "OPENLF2_DEPENDENCY_PROVIDER must be conan, system, switch, vita or web")
endif()

# Translated languages draw their text with TrueType fonts through SDL3_ttf. It is optional: without it the
# build keeps only the default language (the original's bitmap font), and scripts are told so.
option(OPENLF2_TEXT_RENDERING "Render translated text with SDL3_ttf" ON)
option(OPENLF2_FETCH_SDL3_TTF "Build SDL3_ttf from its release archive when it is not installed (needs FreeType)" OFF)
set(openlf2_text_source src/adapters/sdl/text_renderer_stub.cpp)
if(OPENLF2_TEXT_RENDERING)
    find_package(SDL3_ttf 3.2 CONFIG QUIET)
    if(NOT TARGET SDL3_ttf::SDL3_ttf AND OPENLF2_FETCH_SDL3_TTF)
        include(FetchContent)
        FetchContent_Declare(SDL3_ttf
            URL https://github.com/libsdl-org/SDL_ttf/releases/download/release-3.2.2/SDL3_ttf-3.2.2.tar.gz
            URL_HASH SHA256=63547d58d0185c833213885b635a2c0548201cc8f301e6587c0be1a67e1e045d)
        # The archive has no bundled FreeType; text shaping and color emoji are not needed here.
        set(BUILD_SHARED_LIBS OFF)
        set(SDLTTF_VENDORED OFF)
        set(SDLTTF_HARFBUZZ OFF)
        set(SDLTTF_PLUTOSVG OFF)
        set(SDLTTF_SAMPLES OFF)
        set(SDLTTF_INSTALL OFF)
        FetchContent_MakeAvailable(SDL3_ttf)
        unset(BUILD_SHARED_LIBS)
    endif()
    if(TARGET SDL3_ttf::SDL3_ttf)
        set(openlf2_text_source src/adapters/sdl/text_renderer.cpp)
    else()
        message(WARNING "SDL3_ttf not found, so only the default language (bitmap font) will be offered. "
            "Point CMAKE_PREFIX_PATH (or SDL3_ttf_DIR) at an SDL3_ttf install, or use -DOPENLF2_FETCH_SDL3_TTF=ON.")
    endif()
endif()

function(openlf2_target target)
    target_compile_features(${target} PUBLIC cxx_std_23)
    target_include_directories(${target} PUBLIC "${PROJECT_SOURCE_DIR}/include")
    if(OPENLF2_DEPENDENCY_PROVIDER STREQUAL "web")
        target_compile_options(${target} PRIVATE -fexceptions)
    endif()
    if(MSVC)
        target_compile_options(${target} PRIVATE /W4 /WX /permissive- /utf-8)
    else()
        target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow -Werror)
    endif()
endfunction()

add_library(openlf2_core STATIC src/core/files.cpp src/core/json.cpp src/core/settings.cpp)
openlf2_target(openlf2_core)

add_library(openlf2_adapter_compression STATIC src/adapters/compression/decompressor.cpp)
openlf2_target(openlf2_adapter_compression)
target_link_libraries(openlf2_adapter_compression PRIVATE openlf2_core ZLIB::ZLIB BZip2::BZip2)

if(OPENLF2_DEPENDENCY_PROVIDER STREQUAL "web")
    set(openlf2_sha256_source src/adapters/web/sha256.cpp)
else()
    set(openlf2_sha256_source src/adapters/crypto/sha256.cpp)
endif()
add_library(openlf2_adapter_crypto STATIC ${openlf2_sha256_source})
openlf2_target(openlf2_adapter_crypto)
if(OPENLF2_DEPENDENCY_PROVIDER STREQUAL "web")
    target_link_libraries(openlf2_adapter_crypto PRIVATE openlf2_core)
elseif(OPENLF2_DEPENDENCY_PROVIDER STREQUAL "switch")
    target_link_libraries(openlf2_adapter_crypto PRIVATE openlf2_core openlf2_mbedcrypto_target)
else()
    target_link_libraries(openlf2_adapter_crypto PRIVATE openlf2_core OpenSSL::Crypto)
endif()

if(OPENLF2_DEPENDENCY_PROVIDER STREQUAL "web")
    # Persists config.json in the browser's localStorage; Emscripten's own filesystem is temporary.
    add_library(openlf2_adapter_settings STATIC src/adapters/web/settings.cpp)
    openlf2_target(openlf2_adapter_settings)
    target_link_libraries(openlf2_adapter_settings PRIVATE openlf2_core)
endif()

add_library(openlf2_resources STATIC src/resources/installer.cpp src/resources/pack.cpp src/resources/pe_bitmap.cpp
    src/resources/data_file.cpp src/resources/object_data.cpp src/resources/background_data.cpp
    src/resources/stage_data.cpp src/resources/recording.cpp
    src/resources/bitmap.cpp)
openlf2_target(openlf2_resources)
target_link_libraries(openlf2_resources PRIVATE openlf2_core)

add_library(openlf2_engine STATIC src/engine/packages.cpp)
openlf2_target(openlf2_engine)
target_link_libraries(openlf2_engine PRIVATE openlf2_core)

add_library(openlf2_adapter_luajit STATIC src/adapters/luajit/runtime.cpp)
openlf2_target(openlf2_adapter_luajit)
target_link_libraries(openlf2_adapter_luajit PRIVATE openlf2_core LuaJIT::LuaJIT)
add_custom_target(openlf2_build_info
    COMMAND ${CMAKE_COMMAND}
        "-DOPENLF2_SOURCE_DIR=${PROJECT_SOURCE_DIR}"
        "-DOPENLF2_VERSION=${PROJECT_VERSION}"
        "-DOPENLF2_BUILD_INFO=${PROJECT_BINARY_DIR}/generated/openlf2_build_info.hpp"
        -P "${PROJECT_SOURCE_DIR}/cmake/OpenLF2BuildInfo.cmake"
    BYPRODUCTS "${PROJECT_BINARY_DIR}/generated/openlf2_build_info.hpp"
    VERBATIM)
add_dependencies(openlf2_adapter_luajit openlf2_build_info)
target_include_directories(openlf2_adapter_luajit PRIVATE "${PROJECT_BINARY_DIR}/generated")

add_library(openlf2_adapter_music STATIC src/adapters/ffmpeg/music_decoder.cpp)
target_link_libraries(openlf2_adapter_music PRIVATE openlf2_core ${openlf2_ffmpeg_targets})
openlf2_target(openlf2_adapter_music)

if(OPENLF2_DEPENDENCY_PROVIDER STREQUAL "web")
    set(openlf2_network_source src/adapters/web/transport.cpp)
    set(openlf2_download_source src/adapters/web/downloader.cpp)
else()
    set(openlf2_network_source src/adapters/network/transport.cpp)
    set(openlf2_download_source src/adapters/curl/downloader.cpp)
endif()
add_library(openlf2_adapter_network STATIC ${openlf2_network_source})
openlf2_target(openlf2_adapter_network)
target_link_libraries(openlf2_adapter_network PRIVATE openlf2_core)
if(WIN32)
    target_link_libraries(openlf2_adapter_network PRIVATE ws2_32)
endif()

add_library(openlf2_adapter_download STATIC ${openlf2_download_source})
target_link_libraries(openlf2_adapter_download PRIVATE openlf2_core)
if(NOT OPENLF2_DEPENDENCY_PROVIDER STREQUAL "web")
    target_link_libraries(openlf2_adapter_download PRIVATE CURL::libcurl)
endif()
openlf2_target(openlf2_adapter_download)

add_library(openlf2_adapter_sdl STATIC src/adapters/sdl/platform.cpp src/adapters/sdl/setup_screen.cpp
    src/adapters/sdl/frame_upscaler.cpp src/adapters/sdl/gl_upscaler.cpp src/adapters/sdl/sprite_effects.cpp ${openlf2_text_source})
if(NOT EMSCRIPTEN)
    # Emscripten's bundled SDL3 predates the SDL_GPU APIs gpu_upscaler.cpp needs.
    target_sources(openlf2_adapter_sdl PRIVATE src/adapters/sdl/gpu_upscaler.cpp)
endif()
# Phone vibration for the "Rumble" option; other platforms use a no-op stub.
if(ANDROID)
    target_sources(openlf2_adapter_sdl PRIVATE src/adapters/sdl/haptics_android.cpp)
elseif(APPLE AND CMAKE_SYSTEM_NAME STREQUAL "iOS")
    target_sources(openlf2_adapter_sdl PRIVATE src/adapters/sdl/haptics_ios.mm)
    target_link_libraries(openlf2_adapter_sdl PRIVATE "-framework UIKit")
elseif(EMSCRIPTEN)
    target_sources(openlf2_adapter_sdl PRIVATE src/adapters/sdl/haptics_web.cpp)
else()
    target_sources(openlf2_adapter_sdl PRIVATE src/adapters/sdl/haptics_stub.cpp)
endif()
openlf2_target(openlf2_adapter_sdl)
target_link_libraries(openlf2_adapter_sdl PRIVATE openlf2_core SDL3::SDL3)
if(TARGET SDL3_ttf::SDL3_ttf AND OPENLF2_TEXT_RENDERING)
    target_link_libraries(openlf2_adapter_sdl PRIVATE SDL3_ttf::SDL3_ttf)
endif()
if(openlf2_icons AND NOT EMSCRIPTEN)
    # Skipped on web: a canvas has no titlebar to put an icon on; the page favicon covers it.
    target_include_directories(openlf2_adapter_sdl PRIVATE "${openlf2_icons}")
    target_compile_definitions(openlf2_adapter_sdl PRIVATE OPENLF2_HAS_WINDOW_ICON=1)
endif()

if(ANDROID)
    # SDLActivity loads libmain.so and calls SDL_main through SDL's JNI bridge.
    add_library(openlf2 SHARED src/adapters/sdl/entry.cpp src/app/application.cpp)
    set_target_properties(openlf2 PROPERTIES OUTPUT_NAME main)
elseif(APPLE)
    add_executable(openlf2 MACOSX_BUNDLE src/adapters/sdl/entry.cpp src/app/application.cpp)
    if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
        set_target_properties(openlf2 PROPERTIES
            MACOSX_BUNDLE_INFO_PLIST "${PROJECT_SOURCE_DIR}/ios/Info.plist"
            XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)
    else()
        # Conan dylibs use @rpath install names; point them at the bundle's Frameworks dir.
        set_target_properties(openlf2 PROPERTIES
            BUILD_RPATH "@executable_path/../Frameworks"
            INSTALL_RPATH "@executable_path/../Frameworks")
        if(openlf2_icons)
            # The bundle icon (iOS icons are copied in by dist/build-apple.sh).
            set(openlf2_icns "${openlf2_icons}/openlf2.icns")
            set_source_files_properties("${openlf2_icns}" PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
            target_sources(openlf2 PRIVATE "${openlf2_icns}")
            set_target_properties(openlf2 PROPERTIES MACOSX_BUNDLE_ICON_FILE openlf2.icns)
        endif()
    endif()
    # SDL_GetBasePath() returns the bundle's Resources directory on Apple platforms.
    file(GLOB_RECURSE openlf2_bundle_scripts CONFIGURE_DEPENDS
        "${PROJECT_SOURCE_DIR}/scripts/*")
    foreach(script IN LISTS openlf2_bundle_scripts)
        file(RELATIVE_PATH relative_script "${PROJECT_SOURCE_DIR}/scripts" "${script}")
        get_filename_component(script_directory "${relative_script}" DIRECTORY)
        set_source_files_properties("${script}" PROPERTIES
            MACOSX_PACKAGE_LOCATION "Resources/scripts/${script_directory}")
    endforeach()
    target_sources(openlf2 PRIVATE ${openlf2_bundle_scripts})
else()
    add_executable(openlf2 src/adapters/sdl/entry.cpp src/app/application.cpp)
    if(WIN32)
        set_target_properties(openlf2 PROPERTIES WIN32_EXECUTABLE TRUE)
        target_compile_definitions(openlf2 PRIVATE OPENLF2_GUI_SUBSYSTEM=1)
    endif()
    if(WIN32 AND openlf2_icons)
        # The executable's icon: a resource script naming the rendered .ico.
        enable_language(RC)
        target_sources(openlf2 PRIVATE "${openlf2_icons}/openlf2.rc")
    endif()
endif()
openlf2_target(openlf2)
# Browser host callbacks belong to its main thread. Other platforms can use
# a simulation worker when their toolchain supplies native threads.
if(NOT EMSCRIPTEN)
    find_package(Threads QUIET)
endif()
option(OPENLF2_SIMULATION_THREADS "Adaptively overlap live Lua frames with main-thread presentation" ${Threads_FOUND})
if(OPENLF2_SIMULATION_THREADS AND Threads_FOUND AND NOT EMSCRIPTEN)
    target_compile_definitions(openlf2 PRIVATE OPENLF2_SIMULATION_THREADS)
    # On Vita, FFmpeg's pkg-config flags (-pthread) already link libpthread; a second -lpthread links its members twice.
    if(NOT OPENLF2_DEPENDENCY_PROVIDER STREQUAL "vita")
        target_link_libraries(openlf2 PRIVATE Threads::Threads)
    endif()
endif()
# Web, Switch and Vita build LuaJIT without JIT; iOS doesn't permit JIT for ordinary apps.
if(ANDROID OR CMAKE_SYSTEM_NAME STREQUAL "Linux" OR CMAKE_SYSTEM_NAME STREQUAL "Windows"
    OR CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    target_compile_definitions(openlf2 PRIVATE OPENLF2_DEFAULT_JIT=1)
else()
    target_compile_definitions(openlf2 PRIVATE OPENLF2_DEFAULT_JIT=0)
endif()
target_link_libraries(openlf2 PRIVATE openlf2_engine openlf2_resources openlf2_adapter_sdl
    openlf2_adapter_luajit openlf2_adapter_compression openlf2_adapter_crypto openlf2_adapter_music openlf2_adapter_network openlf2_adapter_download SDL3::SDL3)
if(OPENLF2_DEPENDENCY_PROVIDER STREQUAL "web")
    target_link_libraries(openlf2 PRIVATE openlf2_adapter_settings)
    target_link_options(openlf2 PRIVATE
        -fexceptions -sASYNCIFY=1 -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=134217728
        -sASYNCIFY_STACK_SIZE=65536 -sSTACK_SIZE=1048576
        -sINVOKE_RUN=0 -sFORCE_FILESYSTEM=1
        # openlf2_adapter_settings's EM_JS glue needs these explicitly.
        "-sDEFAULT_LIBRARY_FUNCS_TO_INCLUDE=$lengthBytesUTF8,$stringToUTF8,$UTF8ToString"
        -sEXPORTED_RUNTIME_METHODS=FS,callMain
        "--preload-file" "${PROJECT_SOURCE_DIR}/scripts@/scripts")
    configure_file("${PROJECT_SOURCE_DIR}/dist/web/index.html" "${CMAKE_CURRENT_BINARY_DIR}/index.html" COPYONLY)
elseif(OPENLF2_DEPENDENCY_PROVIDER STREQUAL "switch")
    target_link_libraries(openlf2 PRIVATE PkgConfig::OPENLF2_EGL)
    if(NOT OPENLF2_LICENSE_DIR OR NOT EXISTS "${OPENLF2_LICENSE_DIR}/LICENSE-OpenLF2.txt")
        message(FATAL_ERROR "Switch build requires a staged OPENLF2_LICENSE_DIR")
    endif()
    include(dkp-asset-folder)
    dkp_add_asset_target(openlf2_romfs "${CMAKE_CURRENT_BINARY_DIR}/romfs")
    file(GLOB_RECURSE openlf2_switch_scripts CONFIGURE_DEPENDS
        "${PROJECT_SOURCE_DIR}/scripts/*")
    foreach(script IN LISTS openlf2_switch_scripts)
        file(RELATIVE_PATH relative_script "${PROJECT_SOURCE_DIR}" "${script}")
        set(romfs_file "${CMAKE_CURRENT_BINARY_DIR}/romfs/${relative_script}")
        configure_file("${script}" "${romfs_file}" COPYONLY)
        set_property(TARGET openlf2_romfs APPEND PROPERTY DKP_ASSET_FILES "${romfs_file}")
    endforeach()
    file(GLOB openlf2_switch_licenses CONFIGURE_DEPENDS "${OPENLF2_LICENSE_DIR}/*")
    foreach(license_file IN LISTS openlf2_switch_licenses)
        get_filename_component(license_name "${license_file}" NAME)
        set(romfs_file "${CMAKE_CURRENT_BINARY_DIR}/romfs/licenses/${license_name}")
        configure_file("${license_file}" "${romfs_file}" COPYONLY)
        set_property(TARGET openlf2_romfs APPEND PROPERTY DKP_ASSET_FILES "${romfs_file}")
    endforeach()
    # NACP name/author/version for the NRO; VERSION tracks project() above automatically.
    nx_generate_nacp(OUTPUT openlf2.nacp NAME "OpenLF2" AUTHOR "OpenLF2 contributors" VERSION "${PROJECT_VERSION}")
    if(openlf2_icons AND EXISTS "${openlf2_icons}/switch/icon.jpg")
        nx_create_nro(openlf2 ROMFS openlf2_romfs ICON "${openlf2_icons}/switch/icon.jpg" NACP openlf2.nacp)
    else()
        nx_create_nro(openlf2 ROMFS openlf2_romfs NACP openlf2.nacp)
    endif()
elseif(OPENLF2_DEPENDENCY_PROVIDER STREQUAL "vita")
    if(NOT OPENLF2_LICENSE_DIR OR NOT EXISTS "${OPENLF2_LICENSE_DIR}/LICENSE-OpenLF2.txt")
        message(FATAL_ERROR "Vita build requires a staged OPENLF2_LICENSE_DIR")
    endif()
    if(NOT OPENLF2_VITA_CA_BUNDLE OR NOT EXISTS "${OPENLF2_VITA_CA_BUNDLE}")
        message(FATAL_ERROR "Vita build requires a staged OPENLF2_VITA_CA_BUNDLE")
    endif()
    target_link_libraries(openlf2 PRIVATE PkgConfig::OPENLF2_MPG123 PkgConfig::OPENLF2_MBEDTLS)
    include("${VITASDK}/share/vita.cmake")
    vita_create_self(eboot.bin openlf2)
    file(GLOB_RECURSE openlf2_vita_scripts CONFIGURE_DEPENDS
        "${PROJECT_SOURCE_DIR}/scripts/*")
    foreach(script IN LISTS openlf2_vita_scripts)
        file(RELATIVE_PATH relative_script "${PROJECT_SOURCE_DIR}" "${script}")
        list(APPEND openlf2_vita_files "${script}" "${relative_script}")
    endforeach()
    file(GLOB openlf2_vita_licenses CONFIGURE_DEPENDS "${OPENLF2_LICENSE_DIR}/*")
    foreach(license_file IN LISTS openlf2_vita_licenses)
        get_filename_component(license_name "${license_file}" NAME)
        list(APPEND openlf2_vita_files "${license_file}" "licenses/${license_name}")
    endforeach()
    list(APPEND openlf2_vita_files "${OPENLF2_VITA_CA_BUNDLE}" "certs/ca-certificates.crt")
    if(openlf2_icons AND EXISTS "${openlf2_icons}/vita/icon0.png")
        list(APPEND openlf2_vita_files "${openlf2_icons}/vita/icon0.png" "sce_sys/icon0.png")
    endif()
    vita_create_vpk(openlf2.vpk OLF200001 eboot.bin VERSION 01.01 NAME "OpenLF2"
        FILE ${openlf2_vita_files})
endif()
# SDL startup is itself an adapter boundary and requires SDL's header on the executable.
if(NOT ANDROID AND NOT APPLE AND NOT OPENLF2_DEPENDENCY_PROVIDER STREQUAL "vita"
    AND NOT OPENLF2_DEPENDENCY_PROVIDER STREQUAL "web")
    add_custom_target(openlf2_scripts ALL
        COMMAND ${CMAKE_COMMAND} -E copy_directory "${PROJECT_SOURCE_DIR}/scripts" "$<TARGET_FILE_DIR:openlf2>/scripts"
        COMMENT "Copying project Lua modules")
    add_dependencies(openlf2 openlf2_scripts)
endif()

if(APPLE)
    install(TARGETS openlf2 BUNDLE DESTINATION .)
elseif(NOT ANDROID)
    install(TARGETS openlf2 RUNTIME DESTINATION bin)
    install(DIRECTORY scripts DESTINATION bin)
    install(FILES dist/io.github.openlf2.OpenLF2.desktop DESTINATION share/applications)
    install(FILES dist/io.github.openlf2.OpenLF2.mime.xml DESTINATION share/mime/packages)
    install(FILES dist/io.github.openlf2.OpenLF2.svg DESTINATION share/icons/hicolor/scalable/apps)
    if(openlf2_icons)
        install(DIRECTORY "${openlf2_icons}/hicolor" DESTINATION share/icons)
    endif()
    install(FILES dist/io.github.openlf2.OpenLF2.metainfo.xml DESTINATION share/metainfo)
    install(FILES LICENSE README.md DESTINATION share/doc/openlf2)
    if(UNIX)
        # Package managers refresh these caches using their file triggers. For a
        # direct install, update the selected prefix after installing the metadata.
        install(CODE [[
            if("$ENV{DESTDIR}" STREQUAL "")
                find_program(OPENLF2_UPDATE_MIME_DATABASE update-mime-database)
                if(OPENLF2_UPDATE_MIME_DATABASE)
                    execute_process(COMMAND "${OPENLF2_UPDATE_MIME_DATABASE}" "${CMAKE_INSTALL_PREFIX}/share/mime"
                        COMMAND_ERROR_IS_FATAL ANY)
                endif()
                find_program(OPENLF2_UPDATE_DESKTOP_DATABASE update-desktop-database)
                if(OPENLF2_UPDATE_DESKTOP_DATABASE)
                    execute_process(COMMAND "${OPENLF2_UPDATE_DESKTOP_DATABASE}" "${CMAKE_INSTALL_PREFIX}/share/applications"
                        COMMAND_ERROR_IS_FATAL ANY)
                endif()
            endif()
        ]])
    endif()
endif()
