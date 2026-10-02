cmake_minimum_required(VERSION 3.16)
project(sharedesk LANGUAGES C)

# Application folders own their targets and dependencies. Configure from here.
if(APPLE)
    add_subdirectory(viewer)
else()
    add_subdirectory(host)
endif()
