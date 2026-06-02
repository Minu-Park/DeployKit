cmake_minimum_required(VERSION 3.20)
project(DeployKit LANGUAGES NONE)

# Allow parent projects to include DeployKit by module name after add_subdirectory().
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}")
if(NOT CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    set(CMAKE_MODULE_PATH "${CMAKE_MODULE_PATH}" PARENT_SCOPE)
endif()

# Report the resolved module path during parent configuration.
message(STATUS "[DeployKit] Submodule loaded from ${CMAKE_CURRENT_SOURCE_DIR}")
