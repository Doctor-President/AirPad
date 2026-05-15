cmake_minimum_required(VERSION 3.24)
project(umappp-reference CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(FetchContent)

# Defensive: keep umappp from building its own test suite when included as a
# sub-project. Defaults to OFF in sub-project mode already, but make it
# explicit so a future cmake bump doesn't silently turn tests back on.
set(UMAPPP_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)

FetchContent_Declare(
    umappp
    GIT_REPOSITORY https://github.com/libscran/umappp.git
    GIT_TAG v3.3.2
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(umappp)

FetchContent_Declare(
    nlohmann_json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG v3.11.3
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(nlohmann_json)

add_executable(umappp-reference
    src/main.cpp
    src/json_io.cpp
)
target_link_libraries(umappp-reference
    PRIVATE
        umappp
        nlohmann_json::nlohmann_json
)
target_include_directories(umappp-reference PRIVATE src)
target_compile_options(umappp-reference PRIVATE -Wall -Wextra -Wpedantic)
