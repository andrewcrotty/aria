cmake_minimum_required(VERSION 3.12)
project(aria)

#set(CMAKE_BUILD_TYPE Debug)
#set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -pthread -Wall -Wno-long-long -Wno-unused-variable -Wno-variadic-macros -pedantic")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -pthread -Wall -Wno-long-long -Wno-unused-variable -Wno-variadic-macros -pedantic -O2")
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(USE_BARRIER "Use phase barriers in the batch protocols (Aria, AriaFB, Bohm, Calvin, Pwv) on a single node" ON)
option(USE_SMC_BARRIER "Use SmcBarrier" OFF)
option(NO_MANAGER "Use worker 0 as manager" OFF)

if(USE_BARRIER)
    add_definitions(-DUSE_BARRIER)
endif()

if(USE_SMC_BARRIER)
    add_definitions(-DUSE_SMC_BARRIER)

    # SmcBarrier comes from the external/smc_barrier submodule and needs a static
    # AsmJit at the revision its flake pins (barrier_bench's dev shell exports it
    # as $ASMJIT).
    set(ASMJIT_ROOT "$ENV{ASMJIT}" CACHE PATH "AsmJit install prefix (include/, lib/libasmjit.a)")
    if(NOT EXISTS "${ASMJIT_ROOT}/lib/libasmjit.a")
        message(FATAL_ERROR "USE_SMC_BARRIER needs ASMJIT_ROOT/lib/libasmjit.a (ASMJIT_ROOT='${ASMJIT_ROOT}')")
    endif()
    set(SMC_DIR ${CMAKE_SOURCE_DIR}/external/smc_barrier)
    add_library(smc_barrier STATIC ${SMC_DIR}/src/smc_barrier.cpp)
    target_include_directories(smc_barrier PUBLIC ${SMC_DIR}/include PRIVATE ${ASMJIT_ROOT}/include)
    target_compile_definitions(smc_barrier PRIVATE ASMJIT_STATIC)
    target_link_libraries(smc_barrier PRIVATE ${ASMJIT_ROOT}/lib/libasmjit.a rt)
endif()

if(NO_MANAGER)
    add_definitions(-DNO_MANAGER)
endif()

find_library(jemalloc_lib jemalloc) # jemalloc 5.0

# additional target to perform clang-format run, requires clang-format

# get all project files
file(GLOB_RECURSE ALL_SOURCE_FILES benchmark/*.h common/*.h core/*.h protocol/*.h bench*.cpp)

add_custom_target(
        format
        COMMAND clang-format
        -style=LLVM
        -i
        -sort-includes
        ${ALL_SOURCE_FILES}
)

include_directories(${CMAKE_SOURCE_DIR})

file(GLOB_RECURSE COMMON_SOURCE_FILES common/*.cpp)
add_library(common STATIC ${COMMON_SOURCE_FILES})

# Link glog through its CMake target everywhere: glog >= 0.7 refuses to be
# included without the definitions that target carries.
find_package(glog REQUIRED)
find_package(gflags REQUIRED)
target_link_libraries(common ${jemalloc_lib} glog::glog gflags)
if(USE_SMC_BARRIER)
    target_link_libraries(common smc_barrier)
endif()

add_executable(bench_tpcc bench_tpcc.cpp)
target_link_libraries(bench_tpcc common)

add_executable(bench_ycsb bench_ycsb.cpp)
target_link_libraries(bench_ycsb common)
