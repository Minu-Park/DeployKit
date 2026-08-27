# RuntimeSignature.cmake
# Reusable install-time helpers for conditional runtime dependency analysis.

function(deploykit_runtime_file_fingerprint path output_variable)
    # @brief Returns a stable metadata fingerprint for a file or runtime directory.
    # @param path File or directory to inspect.
    # @param output_variable Variable receiving the SHA-256 fingerprint.
    # @note Directory fingerprints cover runtime-shaped files only; content changes
    #       that preserve size and timestamp can be forced through a clean install.
    if(NOT path OR NOT EXISTS "${path}")
        set(${output_variable} "missing" PARENT_SCOPE)
        return()
    endif()

    set(serialized "path=${path}\n")
    if(IS_DIRECTORY "${path}")
        file(GLOB_RECURSE fingerprint_files
            LIST_DIRECTORIES false
            "${path}/*.dll"
            "${path}/*.DLL"
            "${path}/*.exe"
            "${path}/*.EXE"
            "${path}/*.cti"
            "${path}/*.CTI"
        )
        list(SORT fingerprint_files)
        foreach(fingerprint_file IN LISTS fingerprint_files)
            file(RELATIVE_PATH relative_path "${path}" "${fingerprint_file}")
            file(SIZE "${fingerprint_file}" file_size)
            file(TIMESTAMP "${fingerprint_file}" file_timestamp UTC)
            string(APPEND serialized
                "${relative_path}|${file_size}|${file_timestamp}\n")
        endforeach()
    else()
        file(SIZE "${path}" file_size)
        file(TIMESTAMP "${path}" file_timestamp UTC)
        string(APPEND serialized "file|${file_size}|${file_timestamp}\n")
    endif()

    string(SHA256 fingerprint "${serialized}")
    set(${output_variable} "${fingerprint}" PARENT_SCOPE)
endfunction()

function(deploykit_runtime_import_fingerprint import_tool binary output_variable)
    # @brief Fingerprints the direct PE imports of a binary when dumpbin is available.
    # @param import_tool Path to dumpbin, or an empty value for the safe fallback.
    # @param binary Executable or DLL whose direct imports are inspected.
    # @param output_variable Variable receiving the import fingerprint.
    # @note The fallback hashes the complete binary, which preserves correctness but
    #       intentionally forfeits the fast path when no import-inspection tool exists.
    if(NOT binary OR NOT EXISTS "${binary}")
        set(${output_variable} "missing" PARENT_SCOPE)
        return()
    endif()

    if(import_tool AND EXISTS "${import_tool}")
        execute_process(
            COMMAND "${import_tool}" /DEPENDENTS "${binary}"
            RESULT_VARIABLE import_result
            OUTPUT_VARIABLE import_output
            ERROR_VARIABLE import_error
            OUTPUT_STRIP_TRAILING_WHITESPACE
        )
        if(import_result EQUAL 0)
            string(REPLACE "\r\n" "\n" import_output "${import_output}")
            string(REPLACE "\r" "\n" import_output "${import_output}")
            string(REGEX MATCHALL
                "[ \t]+[^ \t\n]+\\.[Dd][Ll][Ll]"
                dependency_matches
                "${import_output}"
            )

            set(dependency_names)
            foreach(dependency_match IN LISTS dependency_matches)
                string(STRIP "${dependency_match}" dependency_name)
                string(TOLOWER "${dependency_name}" dependency_name)
                list(APPEND dependency_names "${dependency_name}")
            endforeach()
            list(REMOVE_DUPLICATES dependency_names)
            list(SORT dependency_names)
            string(JOIN "\n" dependency_text ${dependency_names})
            string(SHA256 fingerprint "${dependency_text}")
            set(${output_variable} "imports:${fingerprint}" PARENT_SCOPE)
            return()
        endif()
    endif()

    file(SHA256 "${binary}" binary_hash)
    set(${output_variable} "content:${binary_hash}" PARENT_SCOPE)
endfunction()

function(deploykit_runtime_signature_is_current stamp_file expected_signature bundle_root output_variable)
    # @brief Checks a runtime-closure stamp and every recorded output path.
    # @param stamp_file Persistent stamp generated after a successful closure pass.
    # @param expected_signature Current deployment-input signature.
    # @param bundle_root Root used to resolve recorded relative output paths.
    # @param output_variable Variable receiving TRUE or FALSE.
    if(NOT stamp_file OR NOT EXISTS "${stamp_file}")
        set(${output_variable} FALSE PARENT_SCOPE)
        return()
    endif()

    file(STRINGS "${stamp_file}" stamp_lines)
    list(LENGTH stamp_lines stamp_line_count)
    if(stamp_line_count LESS 2)
        set(${output_variable} FALSE PARENT_SCOPE)
        return()
    endif()
    list(GET stamp_lines 0 stored_signature)
    if(NOT "${stored_signature}" STREQUAL "${expected_signature}")
        set(${output_variable} FALSE PARENT_SCOPE)
        return()
    endif()
    list(REMOVE_AT stamp_lines 0)
    foreach(recorded_path IN LISTS stamp_lines)
        if(recorded_path STREQUAL "")
            continue()
        endif()
        if(NOT EXISTS "${bundle_root}/${recorded_path}")
            set(${output_variable} FALSE PARENT_SCOPE)
            return()
        endif()
    endforeach()

    set(${output_variable} TRUE PARENT_SCOPE)
endfunction()

function(deploykit_runtime_write_signature stamp_file signature bundle_root)
    # @brief Records a successful runtime closure and its managed output paths.
    # @param stamp_file Destination stamp outside the distributable bundle.
    # @param signature Deployment-input signature that produced the closure.
    # @param bundle_root Root used to store relative managed paths.
    # @param ARGN Managed files or directories to record.
    get_filename_component(stamp_directory "${stamp_file}" DIRECTORY)
    file(MAKE_DIRECTORY "${stamp_directory}")

    set(recorded_paths)
    foreach(managed_path IN LISTS ARGN)
        if(NOT EXISTS "${managed_path}")
            continue()
        endif()
        if(IS_DIRECTORY "${managed_path}")
            file(GLOB_RECURSE managed_files
                LIST_DIRECTORIES false
                "${managed_path}/*"
            )
            list(APPEND recorded_paths ${managed_files})
        else()
            list(APPEND recorded_paths "${managed_path}")
        endif()
    endforeach()

    list(REMOVE_DUPLICATES recorded_paths)
    set(relative_paths)
    foreach(recorded_path IN LISTS recorded_paths)
        file(RELATIVE_PATH relative_path "${bundle_root}" "${recorded_path}")
        if(NOT relative_path STREQUAL "")
            list(APPEND relative_paths "${relative_path}")
        endif()
    endforeach()
    list(SORT relative_paths)

    file(WRITE "${stamp_file}" "${signature}\n")
    foreach(relative_path IN LISTS relative_paths)
        file(APPEND "${stamp_file}" "${relative_path}\n")
    endforeach()
endfunction()
