cmake_minimum_required(VERSION 3.5.0)
project(screen_recorder)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

add_library(entry SHARED
    napi_init.cpp
    screen_recorder_native.cpp
)

target_include_directories(entry PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(entry PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_avscreen_capture.so
)
