#!/usr/bin/env bash
set -euo pipefail

lua_root=/workspace/build/web/vendor/lua-5.2.4
ffmpeg_root=/workspace/build/web/vendor/ffmpeg-7.1.5
sdl_root=/workspace/build/web/vendor/SDL3-3.4.14
freetype_root=/workspace/build/web/vendor/freetype-2.13.2
sdl_ttf_root=/workspace/build/web/vendor/SDL3_ttf-3.2.2
prefix=/workspace/build/web/prefix
export EM_CACHE=/workspace/build/web/emscripten-cache

mkdir -p "$EM_CACHE/sysroot/lib/pkgconfig" "$prefix"
embuilder build zlib bzip2
# SDL 3.4 instead of Emscripten's bundled 3.2 port: 3.2 paints black letterbox bars over each presented frame and
# stops resizing the canvas once the window is fullscreen.
if [[ ! -f "$prefix/lib/libSDL3.a" ]]; then
    emcmake cmake -S "$sdl_root" -B /workspace/build/web/sdl -G 'Unix Makefiles' \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_TEST_LIBRARY=OFF
    cmake --build /workspace/build/web/sdl -j4
    cmake --install /workspace/build/web/sdl
fi
# SDL3_ttf (the translated languages' text) over a FreeType without its optional codecs. SDL3_ttf uses CMake's
# FindFreetype, which does not look in the prefix under Emscripten, so the library and headers are named.
freetype_options=(-DFREETYPE_LIBRARY="$prefix/lib/libfreetype.a" -DFREETYPE_INCLUDE_DIR_ft2build="$prefix/include/freetype2"
    -DFREETYPE_INCLUDE_DIR_freetype2="$prefix/include/freetype2")
if [[ ! -f "$prefix/lib/libfreetype.a" ]]; then
    emcmake cmake -S "$freetype_root" -B /workspace/build/web/freetype -G 'Unix Makefiles' \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DBUILD_SHARED_LIBS=OFF \
        -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
    cmake --build /workspace/build/web/freetype -j4
    cmake --install /workspace/build/web/freetype
fi
if [[ ! -f "$prefix/lib/libSDL3_ttf.a" ]]; then
    emcmake cmake -S "$sdl_ttf_root" -B /workspace/build/web/sdl-ttf -G 'Unix Makefiles' \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
        -DSDL3_DIR="$prefix/lib/cmake/SDL3" "${freetype_options[@]}" -DSDLTTF_VENDORED=OFF -DSDLTTF_HARFBUZZ=OFF \
        -DSDLTTF_PLUTOSVG=OFF -DSDLTTF_SAMPLES=OFF
    cmake --build /workspace/build/web/sdl-ttf -j4
    cmake --install /workspace/build/web/sdl-ttf
fi
make -B -C "$lua_root/src" -j4 liblua.a CC=emcc AR='emar rcu' RANLIB=emranlib MYCFLAGS=-O2

if [[ ! -f "$prefix/lib/libavformat.a" ]]; then
    (
        cd "$ffmpeg_root"
        emconfigure ./configure --prefix="$prefix" --target-os=none --arch=wasm32 \
            --enable-cross-compile --cc=emcc --cxx=em++ --ar=emar --ranlib=emranlib \
            --disable-asm --disable-autodetect --disable-network --disable-pthreads \
            --disable-doc --disable-programs --disable-avdevice --disable-avfilter \
            --disable-postproc --disable-everything --disable-shared --enable-static \
            --enable-decoder=wmav1,wmav2,wmapro,mp3float,mp3 --enable-demuxer=asf,mp3 --enable-parser=mpegaudio \
            --enable-swresample
        make -j4
        make install
    )
fi

emcmake cmake -S /workspace -B /workspace/build/web/native -G 'Unix Makefiles' \
    -DOPENLF2_DEPENDENCY_PROVIDER=web \
    -DOPENLF2_WEB_LUA_ROOT="$lua_root" \
    -DOPENLF2_WEB_FFMPEG_ROOT="$prefix" \
    -DSDL3_DIR="$prefix/lib/cmake/SDL3" -DSDL3_ttf_DIR="$prefix/lib/cmake/SDL3_ttf" "${freetype_options[@]}" \
    -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
    -DOPENLF2_ICON_DIR=/workspace/build/web/icons \
    -DCMAKE_BUILD_TYPE=Release
cmake --build /workspace/build/web/native -j4
