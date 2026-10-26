cmake_minimum_required(VERSION 3.28)
project(devcontainer-timezone-agent LANGUAGES C CXX)

# Target defaults
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(APPLE)
	set(CMAKE_OSX_DEPLOYMENT_TARGET 13.3)
endif()

# Build configuration
if(CMAKE_BUILD_TYPE STREQUAL Release)
	set(CMAKE_COMPILE_WARNING_AS_ERROR ON)
	set(CMAKE_C_VISIBILITY_PRESET hidden)
	set(CMAKE_CXX_VISIBILITY_PRESET hidden)
endif()

# Clang & GCC diagnostics.
if(CMAKE_CXX_COMPILER_ID STREQUAL Clang OR CMAKE_CXX_COMPILER_ID STREQUAL GNU)
	add_compile_options(-fdiagnostics-color -Wall -Wextra -Wpedantic)
endif()

# libfswatch
include(FetchContent)
block()
	set(CMAKE_CXX_STANDARD 17)
	set(BUILD_LIBS_ONLY ON)
	set(BUILD_SHARED_LIBS OFF)
	set(BUILD_TESTING OFF)
	set(USE_NLS OFF)
	FetchContent_Declare(
		fswatch
		GIT_REPOSITORY https://github.com/emcrisostomo/fswatch.git
		GIT_TAG 1.22.0
		GIT_SHALLOW TRUE
		EXCLUDE_FROM_ALL
	)
	FetchContent_MakeAvailable(fswatch)
endblock()

# Agent target
add_executable(devcontainer-timezone-agent agent.cc)
target_compile_options(devcontainer-timezone-agent PRIVATE -Wall -Wextra)
target_link_libraries(devcontainer-timezone-agent PRIVATE libfswatch)

option(AGENT_STATIC "Link statically, for portable Linux release binaries" OFF)
if(AGENT_STATIC)
	target_link_options(devcontainer-timezone-agent PRIVATE -static)
endif()

# Install
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
	set(CMAKE_INSTALL_PREFIX "$ENV{HOME}/.local" CACHE PATH "Install prefix" FORCE)
endif()

include(GNUInstallDirs)
set(AGENT_LABEL com.laverdet.devcontainer-timezone)
set(AGENT_REPO laverdet/devcontainer)
set(AGENT_RELEASE latest CACHE STRING "GitHub release the installer downloads from: a v* tag, or latest")
set(AGENT_BIN "${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_BINDIR}/devcontainer-timezone-agent")

configure_file(
	install.sh.in ${CMAKE_BINARY_DIR}/install.sh @ONLY
	FILE_PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE
)

install(TARGETS devcontainer-timezone-agent RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
string(JOIN "\" \"" AGENT_INSTALL_CMD sh "${CMAKE_BINARY_DIR}/install.sh" --local "${AGENT_BIN}")
install(CODE "execute_process(COMMAND \"${AGENT_INSTALL_CMD}\" COMMAND_ERROR_IS_FATAL ANY)")

if(NOT TARGET uninstall)
	add_custom_target(uninstall
		COMMAND sh ${CMAKE_BINARY_DIR}/install.sh --uninstall --local "${AGENT_BIN}"
		VERBATIM)
endif()
