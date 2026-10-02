cmake_minimum_required(VERSION 3.16)
# The current Homebrew dependencies require macOS 27. Set this before enabling
# languages so the executable and its bundle metadata have the same minimum.
if(CMAKE_HOST_APPLE AND NOT CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "27.0" CACHE STRING "Minimum macOS version" FORCE)
endif()
project(sharedesk LANGUAGES C)

# Application folders own their targets and dependencies. Configure from here.
if(APPLE)
    add_subdirectory(viewer)
else()
    add_subdirectory(host)
endif()
