# SPDX-License-Identifier: GPL-2.0-only
# nvimx296camerasrc - GStreamer source element: IMX296 raw V4L2 capture +
# fused CUDA ISP (black level -> debayer -> WB*CCM -> tone map -> NV12)
# outputting memory:NVMM buffers. Build natively on the Jetson (JetPack 6).
#
# Build:    mkdir -p build && cd build && cmake .. && make -j$(nproc)
# Install:  sudo make install     (see Install layout below)
# Remove:   sudo xargs rm -v < build/install_manifest.txt
#
# Install layout:
#   plugin  -> GStreamer plugin directory (autodetected from pkg-config
#              `pluginsdir`; override with -DGST_PLUGIN_INSTALL_DIR=...)
#              After install, gst-launch finds nvimx296camerasrc with NO
#              GST_PLUGIN_PATH needed.
#   tuning  -> ${CMAKE_INSTALL_PREFIX}/share/nvimx296camerasrc/
#              imx296_16mm.json; compiled in as the element's default
#              `tuning-file` property value.
#   tools   -> ${CMAKE_INSTALL_PREFIX}/bin/imx296_kernel_test
cmake_minimum_required(VERSION 3.18)

# Must precede project(): CUDA language detection happens there, and the
# stock JetPack image does not put nvcc on PATH.
if(NOT CMAKE_CUDA_COMPILER AND EXISTS /usr/local/cuda/bin/nvcc)
  set(CMAKE_CUDA_COMPILER /usr/local/cuda/bin/nvcc)
endif()
if(NOT CMAKE_CUDA_ARCHITECTURES)
  set(CMAKE_CUDA_ARCHITECTURES 87)   # Orin (Ampere iGPU)
endif()

project(nvimx296camerasrc LANGUAGES C CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

include(GNUInstallDirs)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GST REQUIRED gstreamer-1.0 gstreamer-base-1.0 gstreamer-video-1.0)
find_package(CUDAToolkit REQUIRED)

# ---- install destinations -------------------------------------------------
# GStreamer plugin dir: where gst-launch looks without GST_PLUGIN_PATH.
if(NOT GST_PLUGIN_INSTALL_DIR)
  execute_process(
    COMMAND ${PKG_CONFIG_EXECUTABLE} --variable=pluginsdir gstreamer-1.0
    OUTPUT_VARIABLE GST_PLUGIN_INSTALL_DIR
    OUTPUT_STRIP_TRAILING_WHITESPACE)
endif()
if(NOT GST_PLUGIN_INSTALL_DIR)
  set(GST_PLUGIN_INSTALL_DIR ${CMAKE_INSTALL_FULL_LIBDIR}/gstreamer-1.0)
endif()

set(NVIMX296_DATA_DIR ${CMAKE_INSTALL_FULL_DATADIR}/nvimx296camerasrc)
set(NVIMX296_DEFAULT_TUNING ${NVIMX296_DATA_DIR}/imx296_16mm.json)

message(STATUS "GStreamer plugin install dir: ${GST_PLUGIN_INSTALL_DIR}")
message(STATUS "Default tuning file path:     ${NVIMX296_DEFAULT_TUNING}")

set(JETSON_MM_API /usr/src/jetson_multimedia_api)
set(TEGRA_LIB_DIRS /usr/lib/aarch64-linux-gnu/nvidia /usr/lib/aarch64-linux-gnu/tegra)

# ---- plugin ----------------------------------------------------------------
add_library(gstnvimx296camerasrc SHARED
  src/gstnvimx296camerasrc.cpp
  src/imx296_isp.cu
  src/tuning.cpp
)
target_include_directories(gstnvimx296camerasrc PRIVATE
  ${GST_INCLUDE_DIRS} ${JETSON_MM_API}/include ${CMAKE_CURRENT_SOURCE_DIR}/src
)
target_compile_definitions(gstnvimx296camerasrc PRIVATE
  NVIMX296_DEFAULT_TUNING="${NVIMX296_DEFAULT_TUNING}"
  NVIMX296_SOURCE_TUNING="${CMAKE_CURRENT_SOURCE_DIR}/data/imx296_16mm.json"
)
target_link_directories(gstnvimx296camerasrc PRIVATE ${TEGRA_LIB_DIRS})
target_link_libraries(gstnvimx296camerasrc
  ${GST_LIBRARIES} nvbufsurface EGL CUDA::cudart CUDA::cuda_driver
)
target_compile_options(gstnvimx296camerasrc PRIVATE
  $<$<COMPILE_LANGUAGE:CXX>:-Wall -Wextra -Wno-unused-parameter>
)
set_target_properties(gstnvimx296camerasrc PROPERTIES
  PREFIX "lib" CUDA_SEPARABLE_COMPILATION OFF)

# ---- golden-test tool ------------------------------------------------------
add_executable(imx296_kernel_test tools/imx296_kernel_test.cpp src/imx296_isp.cu src/tuning.cpp)
target_include_directories(imx296_kernel_test PRIVATE
  ${JETSON_MM_API}/include ${CMAKE_CURRENT_SOURCE_DIR}/src)
target_link_libraries(imx296_kernel_test CUDA::cudart CUDA::cuda_driver)

# ---- install ---------------------------------------------------------------
install(TARGETS gstnvimx296camerasrc
        LIBRARY DESTINATION ${GST_PLUGIN_INSTALL_DIR})
install(FILES data/imx296_16mm.json
        DESTINATION ${NVIMX296_DATA_DIR})
install(TARGETS imx296_kernel_test
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES README.md
        DESTINATION ${CMAKE_INSTALL_DATADIR}/doc/nvimx296camerasrc)
