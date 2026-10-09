if(NOT CMAKE_GENERATOR MATCHES "^(Ninja|Ninja Multi-Config|Xcode)$")
    message(FATAL_ERROR "The Swift viewer requires Ninja or Xcode. Configure a fresh build directory with -G Ninja.")
endif()
enable_language(Swift)
find_package(PkgConfig REQUIRED)
find_package(ZLIB REQUIRED)
pkg_check_modules(VNC_CLIENT REQUIRED IMPORTED_TARGET libvncclient>=0.9.15)
find_library(COCOA_FRAMEWORK Cocoa)
find_library(CARBON_FRAMEWORK Carbon)
find_library(SECURITY_FRAMEWORK Security)
find_library(NETWORK_FRAMEWORK Network)
find_library(IMAGEIO_FRAMEWORK ImageIO)
find_library(UTTYPE_FRAMEWORK UniformTypeIdentifiers)
find_library(CRYPTOKIT_FRAMEWORK CryptoKit)

set_source_files_properties(sharedesk-viewer.icns PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
add_executable(sharedesk-viewer MACOSX_BUNDLE
    main.swift ViewerApplication.swift ViewerWindow.swift DesktopView.swift VNCSession.swift
    ConnectionProfiles.swift ProfilePasswords.swift ProfileEditor.swift ConnectionStatistics.swift
    MCPServer.swift MCPHTTPConnection.swift MCPServerWindow.swift MCPControl.swift MCPConnections.swift VNCInputAction.swift
    MCPAuthorization.swift MCPAuthorizationStore.swift
    VNCBridge.c MCPKeychain.c sharedesk-viewer.icns)
target_include_directories(sharedesk-viewer PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_options(sharedesk-viewer PRIVATE "$<$<COMPILE_LANGUAGE:C>:-Wall;-Wextra;-Wpedantic>")
target_link_libraries(sharedesk-viewer PRIVATE PkgConfig::VNC_CLIENT ZLIB::ZLIB ${COCOA_FRAMEWORK} ${CARBON_FRAMEWORK} ${SECURITY_FRAMEWORK} ${NETWORK_FRAMEWORK} ${IMAGEIO_FRAMEWORK} ${UTTYPE_FRAMEWORK} ${CRYPTOKIT_FRAMEWORK})
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

# Only installation/packaging embeds libraries and signs the copied bundle.
# Ordinary builds keep the existing development app and output path.
install(DIRECTORY "$<TARGET_BUNDLE_DIR:sharedesk-viewer>/"
    DESTINATION Sharedesk.app USE_SOURCE_PERMISSIONS
    PATTERN "*.d" EXCLUDE)
install(FILES Install.txt DESTINATION .)
configure_file(package-app.cmake.in "${CMAKE_CURRENT_BINARY_DIR}/package-app.cmake" @ONLY)
install(SCRIPT "${CMAKE_CURRENT_BINARY_DIR}/package-app.cmake")

set(CPACK_GENERATOR DragNDrop)
set(CPACK_PACKAGE_NAME Sharedesk)
set(CPACK_PACKAGE_VERSION 0.1)
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "Private remote-desktop viewer")
set(CPACK_PACKAGE_DIRECTORY "${CMAKE_BINARY_DIR}")
set(CPACK_PACKAGE_FILE_NAME "Sharedesk-${CPACK_PACKAGE_VERSION}-${CMAKE_SYSTEM_PROCESSOR}")
set(CPACK_DMG_VOLUME_NAME Sharedesk)
set(CPACK_DMG_FORMAT UDZO)
set(CPACK_DMG_DISABLE_APPLICATIONS_SYMLINK OFF)
set(CPACK_SOURCE_GENERATOR "")
include(CPack)
