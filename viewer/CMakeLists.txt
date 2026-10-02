if(NOT CMAKE_GENERATOR MATCHES "^(Ninja|Ninja Multi-Config|Xcode)$")
    message(FATAL_ERROR "The Swift viewer requires Ninja or Xcode. Configure a fresh build directory with -G Ninja.")
endif()
enable_language(Swift)
find_package(PkgConfig REQUIRED)
pkg_check_modules(VNC_CLIENT REQUIRED IMPORTED_TARGET libvncclient>=0.9.15)
find_library(COCOA_FRAMEWORK Cocoa)
find_library(CARBON_FRAMEWORK Carbon)

add_executable(sharedesk-viewer MACOSX_BUNDLE
    main.swift ViewerApplication.swift DesktopView.swift VNCSession.swift VNCBridge.c)
target_include_directories(sharedesk-viewer PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_options(sharedesk-viewer PRIVATE "$<$<COMPILE_LANGUAGE:C>:-Wall;-Wextra;-Wpedantic>")
target_link_libraries(sharedesk-viewer PRIVATE PkgConfig::VNC_CLIENT ${COCOA_FRAMEWORK} ${CARBON_FRAMEWORK})
set_target_properties(sharedesk-viewer PROPERTIES
    C_STANDARD 11
    C_STANDARD_REQUIRED YES
    Swift_LANGUAGE_VERSION 6
    # Preserve build-mac/sharedesk-viewer.app for the root build commands.
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
    MACOSX_BUNDLE_BUNDLE_NAME Sharedesk
    MACOSX_BUNDLE_GUI_IDENTIFIER net.sharedesk.viewer
    MACOSX_BUNDLE_BUNDLE_VERSION 1
    MACOSX_BUNDLE_SHORT_VERSION_STRING 0.1
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/viewer-Info.plist.in")
