cmake_minimum_required(VERSION 3.20)
project(DeployKit LANGUAGES CXX)

# DeployKit.cmake를 모듈 경로에 추가하여 부모 프로젝트가 include(DeployKit)할 수 있도록 함
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}")

# 부모 빌드 시스템에 정보 전달
message(STATUS "[DeployKit] Submodule loaded from ${CMAKE_CURRENT_SOURCE_DIR}")
