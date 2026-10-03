# Apply the unified safety patch only to the pinned private dependency.
# Reconfiguration is idempotent. Source mismatches fail without partial edits.
find_program(PATCH_EXECUTABLE patch)
if(NOT PATCH_EXECUTABLE)
    message(FATAL_ERROR "Applying the private LibVNCServer fix requires the patch utility")
endif()
set(patch "${CMAKE_CURRENT_LIST_DIR}/libvncserver-clipboard.patch")
execute_process(COMMAND "${PATCH_EXECUTABLE}" -p1 --batch --forward --fuzz=0 --dry-run -i "${patch}"
    WORKING_DIRECTORY "${SOURCE_DIR}" RESULT_VARIABLE applicable
    OUTPUT_VARIABLE output ERROR_VARIABLE error)
if(NOT applicable EQUAL 0)
    execute_process(COMMAND "${PATCH_EXECUTABLE}" -p1 --batch --reverse --fuzz=0 --dry-run -i "${patch}"
        WORKING_DIRECTORY "${SOURCE_DIR}" RESULT_VARIABLE applied
        OUTPUT_QUIET ERROR_QUIET)
    if(applied EQUAL 0)
        return()
    endif()
    message(FATAL_ERROR "Pinned LibVNCServer source does not match the clipboard patch: ${output}${error}")
endif()
execute_process(COMMAND "${PATCH_EXECUTABLE}" -p1 --batch --forward --fuzz=0 --no-backup-if-mismatch -i "${patch}"
    WORKING_DIRECTORY "${SOURCE_DIR}" RESULT_VARIABLE result
    OUTPUT_VARIABLE output ERROR_VARIABLE error)
if(NOT result EQUAL 0)
    message(FATAL_ERROR "Cannot apply the clipboard patch: ${output}${error}")
endif()
