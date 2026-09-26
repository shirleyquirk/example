cmake_minimum_required(VERSION 3.20)
project(sdm_service_tools CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(sdm_core sdm/src/flash_plan.cpp)
target_include_directories(sdm_core PUBLIC sdm/include)
target_compile_options(sdm_core PUBLIC $<$<CXX_COMPILER_ID:GNU,Clang>:-Wall -Wextra -Wpedantic -Wno-missing-field-initializers>)

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
        tests/test_hil_on_fake.cpp)
    target_include_directories(sdm_tests PRIVATE third_party)
    target_link_libraries(sdm_tests PRIVATE sdm_core sdm_testing)
    add_test(NAME sdm_tests COMMAND sdm_tests)
endif()
