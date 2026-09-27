cmake_minimum_required(VERSION 3.20)
project(sdm_service_tools CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(sdm_core sdm/src/flash_plan.cpp)
target_include_directories(sdm_core PUBLIC sdm/include)
target_compile_options(sdm_core PUBLIC $<$<CXX_COMPILER_ID:GNU,Clang>:-Wall -Wextra -Wpedantic -Wno-missing-field-initializers>)

# Optional: compile-check the AJI (jtagd client) path of jtag_clock.hpp against aji.h from
# https://github.com/intel/libaji_client (src/h). Linking needs libaji_client or libjtag_client.
set(SDM_AJI_INCLUDE_DIR "" CACHE PATH "Directory containing aji.h")
if(SDM_AJI_INCLUDE_DIR)
    add_library(sdm_aji_check OBJECT sdm/src/aji_check.cpp)
    target_include_directories(sdm_aji_check PRIVATE sdm/include ${SDM_AJI_INCLUDE_DIR})
    target_compile_definitions(sdm_aji_check PRIVATE
        WINDOWS=1 UNIX=2 LINUX=3 LITTLE=1 BIG=2 PORT=UNIX SYS=LINUX ENDIAN=LITTLE MODE_64_BIT AJI_NO_MEM_MANAGER)
endif()

add_library(sdm_testing INTERFACE)
target_include_directories(sdm_testing INTERFACE sdm/testing)
target_link_libraries(sdm_testing INTERFACE sdm_core)

add_executable(sdm-flash examples/sdm_flash/main.cpp)
target_link_libraries(sdm-flash PRIVATE sdm_core sdm_testing)

include(CTest)
if(BUILD_TESTING)
    add_executable(sdm_tests
        tests/test_main.cpp
        tests/test_encoding.cpp
        tests/test_qspi_session.cpp
        tests/test_flash_plan.cpp
        tests/test_flash_writer.cpp
        tests/test_hil_on_fake.cpp
        tests/test_erase_and_clock.cpp)
    target_include_directories(sdm_tests PRIVATE third_party)
    target_link_libraries(sdm_tests PRIVATE sdm_core sdm_testing)
    add_test(NAME sdm_tests COMMAND sdm_tests)
endif()
