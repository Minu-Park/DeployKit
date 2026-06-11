# DeployKit.cmake
# Reusable deployment and bundling system for Qt-based cross-platform projects.

function(_deploykit_collect_target_runtime_paths ROOT_TARGET TARGET_NAME OUT_VAR)
    get_property(already_visited GLOBAL PROPERTY "_DEPLOYKIT_VISITED_${ROOT_TARGET}_${TARGET_NAME}")
    if(already_visited)
        set(${OUT_VAR} "" PARENT_SCOPE)
        return()
    endif()
    set_property(GLOBAL PROPERTY "_DEPLOYKIT_VISITED_${ROOT_TARGET}_${TARGET_NAME}" TRUE)

    set(paths "")
    get_target_property(link_libraries ${TARGET_NAME} LINK_LIBRARIES)
    get_target_property(interface_libraries ${TARGET_NAME} INTERFACE_LINK_LIBRARIES)

    foreach(link_item IN LISTS link_libraries interface_libraries)
        if(NOT link_item)
            continue()
        endif()
        if(link_item MATCHES "^\\$<LINK_ONLY:(.*)>$")
            set(link_item "${CMAKE_MATCH_1}")
        endif()

        if(TARGET "${link_item}")
            get_target_property(link_type ${link_item} TYPE)
            if(link_type STREQUAL "SHARED_LIBRARY" OR
               link_type STREQUAL "MODULE_LIBRARY" OR
               link_type STREQUAL "EXECUTABLE")
                list(APPEND paths "$<TARGET_FILE_DIR:${link_item}>")
            endif()

            _deploykit_collect_target_runtime_paths("${ROOT_TARGET}" "${link_item}" child_paths)
            list(APPEND paths ${child_paths})
        elseif(IS_ABSOLUTE "${link_item}" AND EXISTS "${link_item}")
            get_filename_component(link_dir "${link_item}" DIRECTORY)
            list(APPEND paths "${link_dir}")
        endif()
    endforeach()

    list(REMOVE_DUPLICATES paths)
    set(${OUT_VAR} "${paths}" PARENT_SCOPE)
endfunction()

macro(deploykit_configure_bundling TARGET_NAME)
    option(DEPLOYKIT_CLEAN_BUNDLE "Remove the existing bundle directory before installing." OFF)

    # Parse arguments
    set(options)
    set(oneValueArgs MACOSX_ICON)
    set(multiValueArgs EXTRA_LIBS EXTRA_FILES LIBPATHS ANALYZE_BINARIES)
    cmake_parse_arguments(DEPLOY "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    message(STATUS "[DeployKit] Configuring deployment for target: ${TARGET_NAME}")

    _deploykit_collect_target_runtime_paths(${TARGET_NAME} ${TARGET_NAME} deploykit_auto_libpaths)
    list(APPEND DEPLOY_LIBPATHS ${deploykit_auto_libpaths})
    list(REMOVE_DUPLICATES DEPLOY_LIBPATHS)

    # Keep macOS app bundles in the source tree for easy Finder access.
    # On Linux/Windows, prefer the binary tree so out-of-source or shared-folder
    # builds do not have to write executable files back into the source mount.
    if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT OR 
       CMAKE_INSTALL_PREFIX STREQUAL "/usr/local" OR 
       CMAKE_INSTALL_PREFIX MATCHES "^[a-zA-Z]:/Program Files")
        if(APPLE)
            set(deploykit_default_install_prefix "${CMAKE_SOURCE_DIR}/build/bundle")
        else()
            set(deploykit_default_install_prefix "${CMAKE_BINARY_DIR}/bundle")
        endif()
        set(CMAKE_INSTALL_PREFIX "${deploykit_default_install_prefix}" CACHE PATH "Install path prefix" FORCE)
        message(STATUS "[DeployKit] Setting default CMAKE_INSTALL_PREFIX to: ${CMAKE_INSTALL_PREFIX}")
    endif()

    get_target_property(deploykit_target_output_name ${TARGET_NAME} OUTPUT_NAME)
    if(NOT deploykit_target_output_name)
        set(deploykit_target_output_name "${TARGET_NAME}")
    endif()
    set(deploykit_bundle_destination "$<CONFIG>")

    if(APPLE)
        set(deploykit_installed_target_path "${CMAKE_INSTALL_PREFIX}/${deploykit_bundle_destination}/${deploykit_target_output_name}.app")
    else()
        set(deploykit_installed_target_path "${CMAKE_INSTALL_PREFIX}/${deploykit_bundle_destination}/${deploykit_target_output_name}${CMAKE_EXECUTABLE_SUFFIX}")
    endif()

    if(DEPLOYKIT_CLEAN_BUNDLE)
        install(CODE "
            get_filename_component(abs_prefix \"\${CMAKE_INSTALL_PREFIX}\" ABSOLUTE)
            set(deploykit_config_name \"\${CMAKE_INSTALL_CONFIG_NAME}\")
            if(deploykit_config_name STREQUAL \"\")
                set(deploykit_bundle_prefix \"\${abs_prefix}\")
            else()
                set(deploykit_bundle_prefix \"\${abs_prefix}/\${deploykit_config_name}\")
            endif()
            if(EXISTS \"\${deploykit_bundle_prefix}\")
                file(REMOVE_RECURSE \"\${deploykit_bundle_prefix}\")
                if(EXISTS \"\${deploykit_bundle_prefix}\")
                    message(FATAL_ERROR \"[DeployKit] Existing bundle directory is not removable: \${deploykit_bundle_prefix}\")
                endif()
            endif()
        ")
    endif()

    # Set up install destinations depending on platform
    if(APPLE)
        # 1. macOS Deployment
        find_program(MACDEPLOYQT_PATH macdeployqt
            HINTS "${Qt6_DIR}/../../../bin" "${Qt5_DIR}/../../../bin"
            DOC "Path to macdeployqt tool"
        )
        if(NOT MACDEPLOYQT_PATH)
            message(WARNING "[DeployKit] macdeployqt not found! macOS app bundle might not be standalone.")
        else()
            message(STATUS "[DeployKit] Found macdeployqt: ${MACDEPLOYQT_PATH}")
        endif()

        # Set bundle destination to root of the install directory
        install(TARGETS ${TARGET_NAME}
            BUNDLE DESTINATION ${deploykit_bundle_destination}
            RUNTIME DESTINATION ${deploykit_bundle_destination}/bin
        )

        # Copy extra libraries to the bundle Frameworks directory
        set(deploykit_macos_analyze_binaries "")
        foreach(lib ${DEPLOY_EXTRA_LIBS})
            if(TARGET ${lib})
                install(TARGETS ${lib}
                    LIBRARY DESTINATION ${deploykit_bundle_destination}/${TARGET_NAME}.app/Contents/Frameworks
                    ARCHIVE DESTINATION ${deploykit_bundle_destination}/${TARGET_NAME}.app/Contents/Frameworks
                    RUNTIME DESTINATION ${deploykit_bundle_destination}/${TARGET_NAME}.app/Contents/Frameworks
                )
                get_target_property(lib_type ${lib} TYPE)
                if(lib_type STREQUAL "SHARED_LIBRARY" OR lib_type STREQUAL "MODULE_LIBRARY")
                    list(APPEND deploykit_macos_analyze_binaries
                        "\${bundle_prefix}/${TARGET_NAME}.app/Contents/Frameworks/$<TARGET_FILE_NAME:${lib}>"
                    )
                endif()
            else()
                if(EXISTS "${lib}")
                    install(FILES "${lib}"
                        DESTINATION ${deploykit_bundle_destination}/${TARGET_NAME}.app/Contents/Frameworks
                    )
                    get_filename_component(lib_name "${lib}" NAME)
                    list(APPEND deploykit_macos_analyze_binaries
                        "\${bundle_prefix}/${TARGET_NAME}.app/Contents/Frameworks/${lib_name}"
                    )
                else()
                    message(WARNING "[DeployKit] EXTRA_LIBS entry does not name a target or existing file: ${lib}")
                endif()
            endif()
        endforeach()

        foreach(file ${DEPLOY_EXTRA_FILES})
            if(IS_DIRECTORY "${file}")
                install(DIRECTORY "${file}"
                    DESTINATION ${deploykit_bundle_destination}/${TARGET_NAME}.app/Contents/Frameworks
                    USE_SOURCE_PERMISSIONS
                )
            elseif(EXISTS "${file}")
                install(FILES "${file}"
                    DESTINATION ${deploykit_bundle_destination}/${TARGET_NAME}.app/Contents/Frameworks
                )
                get_filename_component(file_name "${file}" NAME)
                list(APPEND deploykit_macos_analyze_binaries
                    "\${bundle_prefix}/${TARGET_NAME}.app/Contents/Frameworks/${file_name}"
                )
            else()
                message(WARNING "[DeployKit] EXTRA_FILES entry does not exist: ${file}")
            endif()
        endforeach()

        foreach(binary ${DEPLOY_ANALYZE_BINARIES})
            list(APPEND deploykit_macos_analyze_binaries "${binary}")
        endforeach()

        # Execute macdeployqt as a post-install step
        if(MACDEPLOYQT_PATH)
            set(macdeployqt_libpaths "")
            foreach(path ${DEPLOY_LIBPATHS})
                list(APPEND macdeployqt_libpaths "-libpath=${path}")
            endforeach()

            install(CODE "
                get_filename_component(abs_prefix \"\${CMAKE_INSTALL_PREFIX}\" ABSOLUTE)
                set(deploykit_config_name \"\${CMAKE_INSTALL_CONFIG_NAME}\")
                if(deploykit_config_name STREQUAL \"\")
                    set(bundle_prefix \"\${abs_prefix}\")
                else()
                    set(bundle_prefix \"\${abs_prefix}/\${deploykit_config_name}\")
                endif()
                message(STATUS \"[DeployKit] Packaging: Running macdeployqt on \${bundle_prefix}/${TARGET_NAME}.app with libpaths: ${DEPLOY_LIBPATHS}...\")
                execute_process(
                    COMMAND \"${MACDEPLOYQT_PATH}\" \"\${bundle_prefix}/${TARGET_NAME}.app\" ${macdeployqt_libpaths} -verbose=1 -no-codesign
                    RESULT_VARIABLE deploy_res
                    OUTPUT_VARIABLE deploy_out
                    ERROR_VARIABLE deploy_err
                )
                if(deploy_out)
                    message(STATUS \"\${deploy_out}\")
                endif()
                if(deploy_err)
                    message(STATUS \"\${deploy_err}\")
                endif()
                if(NOT deploy_res EQUAL 0 OR deploy_out MATCHES \"ERROR:\" OR deploy_err MATCHES \"ERROR:\")
                    message(FATAL_ERROR \"[DeployKit] macdeployqt failed or reported deployment errors; exit code: \${deploy_res}\")
                endif()

                # Get runtime dependencies of target and copy them recursively
                message(STATUS \"[DeployKit] Packaging: Resolving runtime dependencies recursively...\")
                if(POLICY CMP0207)
                    cmake_policy(SET CMP0207 NEW)
                endif()
                set(binaries_to_analyze 
                    \"\${bundle_prefix}/${TARGET_NAME}.app/Contents/MacOS/${TARGET_NAME}\"
                    ${deploykit_macos_analyze_binaries}
                )
                set(copied_libs \"\")
                set(new_dependencies_found TRUE)
                
                while(new_dependencies_found)
                    set(new_dependencies_found FALSE)
                    
                    file(GET_RUNTIME_DEPENDENCIES
                        EXECUTABLES \${binaries_to_analyze}
                        RESOLVED_DEPENDENCIES_VAR resolved_deps
                        UNRESOLVED_DEPENDENCIES_VAR unresolved_deps
                        CONFLICTING_DEPENDENCIES_PREFIX conflicting_deps
                        DIRECTORIES ${DEPLOY_LIBPATHS}
                    )
                    
                    foreach(dep \${resolved_deps})
                        # Skip system libraries (under /usr/lib or /System)
                        if(dep MATCHES \"^/usr/lib\" OR dep MATCHES \"^/System\")
                            continue()
                        endif()
                        # Skip Qt libraries since macdeployqt already handled them
                        if(dep MATCHES \"Qt.*.framework\")
                            continue()
                        endif()
                        
                        get_filename_component(dep_name \"\${dep}\" NAME)
                        list(FIND copied_libs \"\${dep_name}\" idx)
                        if(idx EQUAL -1)
                            message(STATUS \"[DeployKit] Copying dependency: \${dep}\")

                            if(dep MATCHES \"\\\\.framework/\")
                                string(REGEX REPLACE \"^(.*\\\\.framework)/.*$\" \"\\\\1\" framework_dir \"\${dep}\")
                                get_filename_component(framework_name \"\${framework_dir}\" NAME)
                                if(NOT framework_dir MATCHES \"^\${bundle_prefix}/\")
                                    message(STATUS \"[DeployKit] Copying framework dependency: \${framework_dir}\")
                                    file(INSTALL DESTINATION \"\${bundle_prefix}/${TARGET_NAME}.app/Contents/Frameworks\"
                                        TYPE DIRECTORY
                                        FILES \"\${framework_dir}\"
                                    )
                                endif()
                                list(APPEND copied_libs \"\${framework_name}\")
                                continue()
                            endif()
                            
                            # Resolve real path in case it is a symlink
                            get_filename_component(real_dep \"\${dep}\" REALPATH)
                            
                            # Copy shared library file to Frameworks directory
                            file(INSTALL DESTINATION \"\${bundle_prefix}/${TARGET_NAME}.app/Contents/Frameworks\"
                                TYPE SHARED_LIBRARY
                                FILES \"\${dep}\"
                            )
                            
                            # If symlink, copy the real file too
                            if(NOT \"\${dep}\" STREQUAL \"\${real_dep}\")
                                message(STATUS \"[DeployKit] Copying dependency symlink target: \${real_dep}\")
                                file(INSTALL DESTINATION \"\${bundle_prefix}/${TARGET_NAME}.app/Contents/Frameworks\"
                                    TYPE SHARED_LIBRARY
                                    FILES \"\${real_dep}\"
                                )
                            endif()
                            
                            list(APPEND copied_libs \"\${dep_name}\")
                            list(APPEND binaries_to_analyze \"\${bundle_prefix}/${TARGET_NAME}.app/Contents/Frameworks/\${dep_name}\")
                            set(new_dependencies_found TRUE)
                        endif()
                    endforeach()
                    
                    foreach(dep \${unresolved_deps})
                        # Extract the filename from rpath reference
                        string(REGEX REPLACE \"^@rpath/\" \"\" dep_name \"\${dep}\")
                        
                        list(FIND copied_libs \"\${dep_name}\" idx)
                        if(idx EQUAL -1)
                            # Search for this file name in our DEPLOY_LIBPATHS
                            set(found_path \"\")
                            foreach(path ${DEPLOY_LIBPATHS})
                                if(EXISTS \"\${path}/\${dep_name}\")
                                    set(found_path \"\${path}/\${dep_name}\")
                                    break()
                                endif()
                            endforeach()
                            
                            if(found_path)
                                message(STATUS \"[DeployKit] Copying unresolved dependency (found in search paths): \${found_path}\")

                                if(found_path MATCHES \"\\\\.framework/\")
                                    string(REGEX REPLACE \"^(.*\\\\.framework)/.*$\" \"\\\\1\" framework_dir \"\${found_path}\")
                                    get_filename_component(framework_name \"\${framework_dir}\" NAME)
                                    if(NOT framework_dir MATCHES \"^\${bundle_prefix}/\")
                                        message(STATUS \"[DeployKit] Copying framework dependency: \${framework_dir}\")
                                        file(INSTALL DESTINATION \"\${bundle_prefix}/${TARGET_NAME}.app/Contents/Frameworks\"
                                            TYPE DIRECTORY
                                            FILES \"\${framework_dir}\"
                                        )
                                    endif()
                                    list(APPEND copied_libs \"\${framework_name}\")
                                    continue()
                                endif()
                                
                                # Resolve real path in case it is a symlink
                                get_filename_component(real_found_path \"\${found_path}\" REALPATH)
                                
                                # Copy the file (this copies the symlink)
                                file(INSTALL DESTINATION \"\${bundle_prefix}/${TARGET_NAME}.app/Contents/Frameworks\"
                                    TYPE SHARED_LIBRARY
                                    FILES \"\${found_path}\"
                                )
                                
                                # If symlink, copy the real file too
                                if(NOT \"\${found_path}\" STREQUAL \"\${real_found_path}\")
                                    message(STATUS \"[DeployKit] Copying unresolved symlink target: \${real_found_path}\")
                                    file(INSTALL DESTINATION \"\${bundle_prefix}/${TARGET_NAME}.app/Contents/Frameworks\"
                                        TYPE SHARED_LIBRARY
                                        FILES \"\${real_found_path}\"
                                    )
                                endif()
                                
                                list(APPEND copied_libs \"\${dep_name}\")
                                list(APPEND binaries_to_analyze \"\${bundle_prefix}/${TARGET_NAME}.app/Contents/Frameworks/\${dep_name}\")
                                set(new_dependencies_found TRUE)
                            else()
                                message(WARNING \"[DeployKit] Unresolved dependency not found in search paths: \${dep}\")
                            endif()
                        endif()
                    endforeach()
                endwhile()

            # Ad-hoc codesign the bundle. Sign via /tmp to avoid iCloud/fileprovider
            # xattr interference, and sign inside-out (frameworks then app).
            message(STATUS \"[DeployKit] Ad-hoc code signing \${bundle_prefix}/${TARGET_NAME}.app ...\")
            set(_dk_sign_source \"\${bundle_prefix}/${TARGET_NAME}.app\")
            set(_dk_tmp \"/tmp/_deploykit_sign_${TARGET_NAME}.app\")
            file(REMOVE_RECURSE \"\${_dk_tmp}\")
            execute_process(COMMAND \${CMAKE_COMMAND} -E copy_directory \"\${_dk_sign_source}\" \"\${_dk_tmp}\")
            execute_process(COMMAND xattr -rc \"\${_dk_tmp}\" ERROR_QUIET)

            # Sign frameworks and dylibs first
            file(GLOB _dk_frameworks \"\${_dk_tmp}/Contents/Frameworks/*.framework\")
            file(GLOB _dk_dylibs \"\${_dk_tmp}/Contents/Frameworks/*.dylib\")
            foreach(_dk_item \${_dk_frameworks} \${_dk_dylibs})
                execute_process(
                    COMMAND codesign --force -s - \"\${_dk_item}\"
                    ERROR_QUIET
                )
            endforeach()

            # Sign the top-level app bundle
            execute_process(
                COMMAND codesign --force -s - \"\${_dk_tmp}\"
                RESULT_VARIABLE codesign_res
                ERROR_VARIABLE codesign_err
            )
            if(codesign_res EQUAL 0)
                file(REMOVE_RECURSE \"\${_dk_sign_source}\")
                execute_process(COMMAND \${CMAKE_COMMAND} -E copy_directory \"\${_dk_tmp}\" \"\${_dk_sign_source}\")
                file(REMOVE_RECURSE \"\${_dk_tmp}\")
                message(STATUS \"[DeployKit] Ad-hoc codesign complete.\")
            else()
                file(REMOVE_RECURSE \"\${_dk_tmp}\")
                message(WARNING \"[DeployKit] Ad-hoc codesign failed: \${codesign_err}\")
            endif()
            ")
        endif()

    elseif(WIN32)
        # 2. Windows Deployment
        set(deploykit_runtime_dependency_directories "")
        foreach(path ${DEPLOY_LIBPATHS})
            string(APPEND deploykit_runtime_dependency_directories "\n                        \"${path}\"")
        endforeach()

        find_program(WINDEPLOYQT_PATH windeployqt
            HINTS "${Qt6_DIR}/../../../bin" "${Qt5_DIR}/../../../bin"
            DOC "Path to windeployqt tool"
        )
        if(NOT WINDEPLOYQT_PATH)
            message(WARNING "[DeployKit] windeployqt not found! Windows deployment package might fail to run.")
        else()
            message(STATUS "[DeployKit] Found windeployqt: ${WINDEPLOYQT_PATH}")
        endif()

        # Install target
        install(TARGETS ${TARGET_NAME}
            RUNTIME DESTINATION ${deploykit_bundle_destination}
        )

        # Copy extra libraries next to .exe (they may be implicit imports)
        foreach(lib ${DEPLOY_EXTRA_LIBS})
            if(TARGET ${lib})
                install(TARGETS ${lib}
                    RUNTIME DESTINATION ${deploykit_bundle_destination}
                    LIBRARY DESTINATION ${deploykit_bundle_destination}
                )
            else()
                if(EXISTS "${lib}")
                    install(FILES "${lib}"
                        DESTINATION ${deploykit_bundle_destination}
                    )
                else()
                    message(STATUS "[DeployKit] Non-target dependency specified: ${lib}. Ensure it is copied next to the executable.")
                endif()
            endif()
        endforeach()

        foreach(file ${DEPLOY_EXTRA_FILES})
            if(IS_DIRECTORY "${file}")
                install(DIRECTORY "${file}"
                    DESTINATION ${deploykit_bundle_destination}
                    USE_SOURCE_PERMISSIONS
                )
            elseif(EXISTS "${file}")
                install(FILES "${file}"
                    DESTINATION ${deploykit_bundle_destination}
                )
            else()
                message(WARNING "[DeployKit] EXTRA_FILES entry does not exist: ${file}")
            endif()
        endforeach()

        # Execute windeployqt as a post-install step
        if(WINDEPLOYQT_PATH)
            install(CODE "
                get_filename_component(abs_prefix \"\${CMAKE_INSTALL_PREFIX}\" ABSOLUTE)
                set(deploykit_config_name \"\${CMAKE_INSTALL_CONFIG_NAME}\")
                if(deploykit_config_name STREQUAL \"\")
                    set(bundle_prefix \"\${abs_prefix}\")
                else()
                    set(bundle_prefix \"\${abs_prefix}/\${deploykit_config_name}\")
                endif()
                message(STATUS \"[DeployKit] Packaging: Running windeployqt on \${bundle_prefix}/${TARGET_NAME}.exe...\")
                execute_process(
                    COMMAND \"${WINDEPLOYQT_PATH}\" \"\${bundle_prefix}/${TARGET_NAME}.exe\" --no-compiler-runtime --verbose=1
                    RESULT_VARIABLE deploy_res
                )
                if(NOT deploy_res EQUAL 0)
                    message(FATAL_ERROR \"[DeployKit] windeployqt failed with exit code: \${deploy_res}\")
                endif()
            ")
        endif()

        install(CODE "
            get_filename_component(abs_prefix \"\${CMAKE_INSTALL_PREFIX}\" ABSOLUTE)
            set(deploykit_config_name \"\${CMAKE_INSTALL_CONFIG_NAME}\")
            if(deploykit_config_name STREQUAL \"\")
                set(bundle_prefix \"\${abs_prefix}\")
            else()
                set(bundle_prefix \"\${abs_prefix}/\${deploykit_config_name}\")
            endif()
            message(STATUS \"[DeployKit] Windows Packaging: Resolving runtime dependencies recursively...\")
            if(POLICY CMP0207)
                cmake_policy(SET CMP0207 NEW)
            endif()

            set(binaries_to_analyze \"\${bundle_prefix}/${TARGET_NAME}.exe\")
            file(GLOB existing_bundle_dlls \"\${bundle_prefix}/*.dll\")
            set(copied_libs \"\")
            foreach(existing_bundle_dll \${existing_bundle_dlls})
                get_filename_component(existing_bundle_name \"\${existing_bundle_dll}\" NAME)
                list(APPEND copied_libs \"\${existing_bundle_name}\")
            endforeach()

            set(new_dependencies_found TRUE)
            while(new_dependencies_found)
                set(new_dependencies_found FALSE)

                file(GET_RUNTIME_DEPENDENCIES
                    EXECUTABLES \${binaries_to_analyze}
                    RESOLVED_DEPENDENCIES_VAR resolved_deps
                    UNRESOLVED_DEPENDENCIES_VAR unresolved_deps
                    CONFLICTING_DEPENDENCIES_PREFIX conflicting_deps
                    DIRECTORIES ${deploykit_runtime_dependency_directories}
                )

                foreach(dep \${resolved_deps})
                    file(TO_CMAKE_PATH \"\${dep}\" dep_cmake)
                    string(TOLOWER \"\${dep_cmake}\" dep_lower)
                    if(dep_lower MATCHES \"^[a-z]:/windows/\")
                        continue()
                    endif()

                    get_filename_component(dep_name \"\${dep}\" NAME)
                    if(dep_name MATCHES \"^Qt[0-9].*\\\\.dll$\")
                        continue()
                    endif()
                    if(CMAKE_INSTALL_CONFIG_NAME MATCHES \"^[Dd][Ee][Bb][Uu][Gg]$\" AND
                       dep_name MATCHES \"^vtkGUISupportQt-.*\\\\.dll$\")
                        message(WARNING \"[DeployKit] Skipping Release VTK Qt runtime for Debug bundle: \${dep}. Build a Release bundle or provide a Debug VTK build for a standalone VTK Qt bundle.\")
                        if(EXISTS \"\${bundle_prefix}/\${dep_name}\")
                            file(REMOVE \"\${bundle_prefix}/\${dep_name}\")
                        endif()
                        list(APPEND copied_libs \"\${dep_name}\")
                        continue()
                    endif()

                    list(FIND copied_libs \"\${dep_name}\" idx)
                    if(idx EQUAL -1)
                        message(STATUS \"[DeployKit] Copying dependency: \${dep}\")
                        file(INSTALL DESTINATION \"\${bundle_prefix}\"
                            TYPE SHARED_LIBRARY
                            FILES \"\${dep}\"
                        )
                        list(APPEND copied_libs \"\${dep_name}\")
                        list(APPEND binaries_to_analyze \"\${bundle_prefix}/\${dep_name}\")
                        set(new_dependencies_found TRUE)
                    endif()
                endforeach()

                foreach(dep \${unresolved_deps})
                    get_filename_component(dep_name \"\${dep}\" NAME)
                    if(dep_name MATCHES \"^api-ms-\" OR
                       dep_name MATCHES \"^ext-ms-\" OR
                       dep_name MATCHES \"^AzureAttest\" OR
                       dep_name MATCHES \"^Hvsi\" OR
                       dep_name MATCHES \"^PdmUtilities\\\\.dll\" OR
                       dep_name MATCHES \"^wpaxholder\\\\.dll\")
                        continue()
                    endif()
                    message(WARNING \"[DeployKit] Unresolved dependency not found in search paths: \${dep}\")
                endforeach()
            endwhile()
        ")

    else()
        # 3. Linux Deployment (Standard RPATH layout)
        find_program(DEPLOYKIT_PATCHELF_EXECUTABLE patchelf)
        if(NOT DEPLOYKIT_PATCHELF_EXECUTABLE)
            message(FATAL_ERROR "[DeployKit] Linux bundling requires patchelf to rewrite bundled ELF RPATH/RUNPATH entries.")
        endif()
        message(STATUS "[DeployKit] Linux: patchelf executable: ${DEPLOYKIT_PATCHELF_EXECUTABLE}")

        install(TARGETS ${TARGET_NAME}
            RUNTIME DESTINATION ${deploykit_bundle_destination}
        )

        # Copy Qt runtime plugins. Debian-style Qt installs keep plugins under
        # <arch-libdir>/qt6/plugins, so prefer qmake's canonical query result.
        set(QT_PLUGINS_TO_COPY
            platforms
            xcbglintegrations
            imageformats
            iconengines
            platformthemes
            egldeviceintegrations
            wayland-decoration-client
            wayland-graphics-integration-client
            wayland-shell-integration
        )
        set(deploykit_qt_plugin_root "")
        set(deploykit_qmake_target "")
        if(TARGET Qt6::qmake)
            set(deploykit_qmake_target Qt6::qmake)
        elseif(TARGET Qt5::qmake)
            set(deploykit_qmake_target Qt5::qmake)
        endif()

        if(deploykit_qmake_target)
            get_target_property(deploykit_qmake_executable ${deploykit_qmake_target} IMPORTED_LOCATION)
            if(deploykit_qmake_executable)
                execute_process(
                    COMMAND "${deploykit_qmake_executable}" -query QT_INSTALL_PLUGINS
                    OUTPUT_VARIABLE deploykit_qmake_plugin_root
                    OUTPUT_STRIP_TRAILING_WHITESPACE
                    RESULT_VARIABLE deploykit_qmake_result
                )
                if(deploykit_qmake_result EQUAL 0 AND EXISTS "${deploykit_qmake_plugin_root}")
                    set(deploykit_qt_plugin_root "${deploykit_qmake_plugin_root}")
                endif()
            endif()
        endif()

        if(NOT deploykit_qt_plugin_root)
            set(deploykit_qt_plugin_candidates "")
            if(Qt6_DIR)
                list(APPEND deploykit_qt_plugin_candidates
                    "${Qt6_DIR}/../../../../plugins"
                    "${Qt6_DIR}/../../../plugins"
                    "${Qt6_DIR}/../../../qt6/plugins"
                    "${Qt6_DIR}/../../../../lib/qt6/plugins"
                )
            endif()
            if(Qt5_DIR)
                list(APPEND deploykit_qt_plugin_candidates
                    "${Qt5_DIR}/../../../../plugins"
                    "${Qt5_DIR}/../../../plugins"
                    "${Qt5_DIR}/../../../qt5/plugins"
                    "${Qt5_DIR}/../../../../lib/qt5/plugins"
                )
            endif()

            foreach(candidate ${deploykit_qt_plugin_candidates})
                get_filename_component(candidate_abs "${candidate}" ABSOLUTE)
                if(EXISTS "${candidate_abs}/platforms")
                    set(deploykit_qt_plugin_root "${candidate_abs}")
                    break()
                endif()
            endforeach()
        endif()

        if(deploykit_qt_plugin_root)
            message(STATUS "[DeployKit] Linux: Qt plugin root: ${deploykit_qt_plugin_root}")
            foreach(plugin_dir ${QT_PLUGINS_TO_COPY})
                if(EXISTS "${deploykit_qt_plugin_root}/${plugin_dir}")
                    install(DIRECTORY "${deploykit_qt_plugin_root}/${plugin_dir}"
                        DESTINATION ${deploykit_bundle_destination}/plugins
                        USE_SOURCE_PERMISSIONS
                    )
                    message(STATUS "[DeployKit] Linux: Copying Qt plugin directory: ${plugin_dir}")
                endif()
            endforeach()
        elseif(TARGET Qt6::Core OR TARGET Qt5::Core)
            message(FATAL_ERROR "[DeployKit] Linux: Qt plugin root not found; bundled Qt applications need the platforms plugin directory.")
        endif()

        # Create qt.conf next to the executable to point to local plugins
        install(CODE "
            get_filename_component(abs_prefix \"\${CMAKE_INSTALL_PREFIX}\" ABSOLUTE)
            set(deploykit_config_name \"\${CMAKE_INSTALL_CONFIG_NAME}\")
            if(deploykit_config_name STREQUAL \"\")
                set(bundle_prefix \"\${abs_prefix}\")
            else()
                set(bundle_prefix \"\${abs_prefix}/\${deploykit_config_name}\")
            endif()
            file(WRITE \"\${bundle_prefix}/qt.conf\" \"[Paths]\\nPlugins = plugins\\nPrefix = .\\n\")
            message(STATUS \"[DeployKit] Created \${bundle_prefix}/qt.conf\")
        ")

        # Install extra libraries to lib/
        set(deploykit_linux_analyze_binaries "")
        foreach(lib ${DEPLOY_EXTRA_LIBS})
            if(TARGET ${lib})
                install(TARGETS ${lib}
                    LIBRARY DESTINATION ${deploykit_bundle_destination}/lib
                    RUNTIME DESTINATION ${deploykit_bundle_destination}
                )
                get_target_property(lib_type ${lib} TYPE)
                if(lib_type STREQUAL "SHARED_LIBRARY" OR lib_type STREQUAL "MODULE_LIBRARY")
                    list(APPEND deploykit_linux_analyze_binaries
                        "\${bundle_prefix}/lib/$<TARGET_FILE_NAME:${lib}>"
                    )
                elseif(lib_type STREQUAL "EXECUTABLE")
                    list(APPEND deploykit_linux_analyze_binaries
                        "\${bundle_prefix}/$<TARGET_FILE_NAME:${lib}>"
                    )
                endif()
            else()
                if(EXISTS "${lib}")
                    install(FILES "${lib}"
                        DESTINATION ${deploykit_bundle_destination}/lib
                    )
                    get_filename_component(lib_name "${lib}" NAME)
                    list(APPEND deploykit_linux_analyze_binaries
                        "\${bundle_prefix}/lib/${lib_name}"
                    )
                else()
                    message(WARNING "[DeployKit] EXTRA_LIBS entry does not name a target or existing file: ${lib}")
                endif()
            endif()
        endforeach()

        foreach(file ${DEPLOY_EXTRA_FILES})
            if(IS_DIRECTORY "${file}")
                install(DIRECTORY "${file}"
                    DESTINATION ${deploykit_bundle_destination}/lib
                    USE_SOURCE_PERMISSIONS
                )
            elseif(EXISTS "${file}")
                install(FILES "${file}"
                    DESTINATION ${deploykit_bundle_destination}/lib
                )
                get_filename_component(file_name "${file}" NAME)
                list(APPEND deploykit_linux_analyze_binaries
                    "\${bundle_prefix}/lib/${file_name}"
                )
            else()
                message(WARNING "[DeployKit] EXTRA_FILES entry does not exist: ${file}")
            endif()
        endforeach()

        foreach(binary ${DEPLOY_ANALYZE_BINARIES})
            list(APPEND deploykit_linux_analyze_binaries "${binary}")
        endforeach()

        # Set RPATH for the executable to find libraries in lib/
        set_target_properties(${TARGET_NAME} PROPERTIES
            INSTALL_RPATH "$ORIGIN/lib"
        )
        message(STATUS "[DeployKit] Linux RPATH configured to \$ORIGIN/lib")

        # Set RPATH for any extra shared library targets to $ORIGIN (libraries are in the same folder as their deps)
        foreach(lib ${DEPLOY_EXTRA_LIBS})
            if(TARGET ${lib})
                get_target_property(lib_type ${lib} TYPE)
                if(lib_type STREQUAL "SHARED_LIBRARY")
                    set_target_properties(${lib} PROPERTIES
                        INSTALL_RPATH "$ORIGIN"
                    )
                    message(STATUS "[DeployKit] Linux RPATH configured for shared target ${lib} to \$ORIGIN")
                endif()
            endif()
        endforeach()

        # Automatically copy runtime dependencies (like VTK, OpenCV) to lib/ recursively
        install(CODE "
            get_filename_component(abs_prefix \"\${CMAKE_INSTALL_PREFIX}\" ABSOLUTE)
            set(deploykit_config_name \"\${CMAKE_INSTALL_CONFIG_NAME}\")
            if(deploykit_config_name STREQUAL \"\")
                set(bundle_prefix \"\${abs_prefix}\")
            else()
                set(bundle_prefix \"\${abs_prefix}/\${deploykit_config_name}\")
            endif()
            message(STATUS \"[DeployKit] Linux Packaging: Resolving runtime dependencies recursively...\")
            if(POLICY CMP0207)
                cmake_policy(SET CMP0207 NEW)
            endif()
            
            file(GLOB_RECURSE qt_plugin_binaries \"\${bundle_prefix}/plugins/*.so\")
            
            set(binaries_to_analyze 
                \"\${bundle_prefix}/${TARGET_NAME}\"
                ${deploykit_linux_analyze_binaries}
                \${qt_plugin_binaries}
            )
            message(STATUS \"[DeployKit] Target binaries to analyze: \${binaries_to_analyze}\")
            set(copied_libs \"\")
            set(new_dependencies_found TRUE)
            
            while(new_dependencies_found)
                set(new_dependencies_found FALSE)
                
                file(GET_RUNTIME_DEPENDENCIES
                    EXECUTABLES \${binaries_to_analyze}
                    RESOLVED_DEPENDENCIES_VAR resolved_deps
                    UNRESOLVED_DEPENDENCIES_VAR unresolved_deps
                    CONFLICTING_DEPENDENCIES_PREFIX conflicting_deps
                    DIRECTORIES ${DEPLOY_LIBPATHS}
                )
                
                foreach(dep \${resolved_deps})
                    # Skip common Linux system libraries to avoid packaging glibc, graphics drivers, x11, etc.
                    if(dep MATCHES \"^/lib\" OR dep MATCHES \"^/lib64\" OR dep MATCHES \"^/usr/lib\" OR dep MATCHES \"^/usr/lib64\")
                        if(dep MATCHES \"ld-linux\" OR dep MATCHES \"libc\\\\.so\" OR dep MATCHES \"libm\\\\.so\" OR dep MATCHES \"libpthread\" OR dep MATCHES \"libdl\\\\.so\" OR dep MATCHES \"libstdc\\\\+\\\\+\" OR dep MATCHES \"libgcc_s\" OR dep MATCHES \"libGL\" OR dep MATCHES \"libX11\" OR dep MATCHES \"libxcb\" OR dep MATCHES \"libasound\" OR dep MATCHES \"fontconfig\" OR dep MATCHES \"freetype\")
                            continue()
                        endif()
                    endif()
                    
                    get_filename_component(dep_name \"\${dep}\" NAME)
                    list(FIND copied_libs \"\${dep_name}\" idx)
                    if(idx EQUAL -1)
                        message(STATUS \"[DeployKit] Copying dependency: \${dep}\")
                        
                        # Resolve real path in case it is a symlink
                        get_filename_component(real_dep \"\${dep}\" REALPATH)
                        
                        # Copy shared library file to lib directory
                        file(INSTALL DESTINATION \"\${bundle_prefix}/lib\"
                            TYPE SHARED_LIBRARY
                            FILES \"\${dep}\"
                        )
                        
                        # If symlink, copy the real file too
                        if(NOT \"\${dep}\" STREQUAL \"\${real_dep}\")
                            message(STATUS \"[DeployKit] Copying dependency symlink target: \${real_dep}\")
                            file(INSTALL DESTINATION \"\${bundle_prefix}/lib\"
                                TYPE SHARED_LIBRARY
                                FILES \"\${real_dep}\"
                            )
                        endif()

                        list(APPEND copied_libs \"\${dep_name}\")
                        list(APPEND binaries_to_analyze \"\${bundle_prefix}/lib/\${dep_name}\")
                        set(new_dependencies_found TRUE)
                    endif()
                endforeach()
                
                foreach(dep \${unresolved_deps})
                    # Attempt to resolve from DEPLOY_LIBPATHS
                    get_filename_component(dep_name \"\${dep}\" NAME)
                    list(FIND copied_libs \"\${dep_name}\" idx)
                    if(idx EQUAL -1)
                        set(found_path \"\")
                        foreach(path ${DEPLOY_LIBPATHS})
                            if(EXISTS \"\${path}/\${dep_name}\")
                                set(found_path \"\${path}/\${dep_name}\")
                                break()
                            endif()
                        endforeach()
                        
                        if(found_path)
                            message(STATUS \"[DeployKit] Copying unresolved dependency (found in search paths): \${found_path}\")
                            get_filename_component(real_found_path \"\${found_path}\" REALPATH)
                            
                            file(INSTALL DESTINATION \"\${bundle_prefix}/lib\"
                                TYPE SHARED_LIBRARY
                                FILES \"\${found_path}\"
                            )
                            if(NOT \"\${found_path}\" STREQUAL \"\${real_found_path}\")
                                file(INSTALL DESTINATION \"\${bundle_prefix}/lib\"
                                    TYPE SHARED_LIBRARY
                                    FILES \"\${real_found_path}\"
                                )
                            endif()
                            
                            list(APPEND copied_libs \"\${dep_name}\")
                            list(APPEND binaries_to_analyze \"\${bundle_prefix}/lib/\${dep_name}\")
                            set(new_dependencies_found TRUE)
                        else()
                            message(WARNING \"[DeployKit] Unresolved dependency not found in search paths: \${dep}\")
                        endif()
                    endif()
                endforeach()
            endwhile()

            function(deploykit_set_linux_rpath binary rpath)
                if(NOT EXISTS \"\${binary}\")
                    message(WARNING \"[DeployKit] RPATH target does not exist: \${binary}\")
                    return()
                endif()

                execute_process(
                    COMMAND \"${DEPLOYKIT_PATCHELF_EXECUTABLE}\" --set-rpath \"\${rpath}\" \"\${binary}\"
                    RESULT_VARIABLE deploykit_patchelf_result
                    ERROR_VARIABLE deploykit_patchelf_error
                    OUTPUT_QUIET
                    ERROR_STRIP_TRAILING_WHITESPACE
                )
                if(NOT deploykit_patchelf_result EQUAL 0)
                    message(FATAL_ERROR \"[DeployKit] patchelf failed for \${binary}: \${deploykit_patchelf_error}\")
                endif()
                message(STATUS \"[DeployKit] RPATH set: \${binary} -> \${rpath}\")
            endfunction()

            deploykit_set_linux_rpath(\"\${bundle_prefix}/${TARGET_NAME}\" \"$ORIGIN/lib\")

            file(GLOB_RECURSE bundled_libs
                \"\${bundle_prefix}/lib/*.so\"
                \"\${bundle_prefix}/lib/*.so.*\"
            )
            list(REMOVE_DUPLICATES bundled_libs)
            foreach(bundled_lib IN LISTS bundled_libs)
                deploykit_set_linux_rpath(\"\${bundled_lib}\" \"$ORIGIN\")
            endforeach()

            file(GLOB_RECURSE bundled_qt_plugins \"\${bundle_prefix}/plugins/*.so\")
            foreach(plugin_binary IN LISTS bundled_qt_plugins)
                deploykit_set_linux_rpath(\"\${plugin_binary}\" \"$ORIGIN/../../lib:$ORIGIN\")
            endforeach()
        ")
    endif()

    # Building the target should also refresh the bundle output.
    add_custom_command(TARGET ${TARGET_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} --install "${CMAKE_BINARY_DIR}" --config "$<CONFIG>"
        COMMENT "[DeployKit] Bundling and installing ${TARGET_NAME} to ${CMAKE_INSTALL_PREFIX}..."
    )

    # Keep an explicit bundle target for manual re-bundling.
    add_custom_target(Bundle${TARGET_NAME}
        COMMAND ${CMAKE_COMMAND} --install "${CMAKE_BINARY_DIR}" --config "$<CONFIG>"
        COMMENT "[DeployKit] Re-bundling and installing ${TARGET_NAME} to ${CMAKE_INSTALL_PREFIX}..."
    )
    add_dependencies(Bundle${TARGET_NAME} ${TARGET_NAME})

    # 4. CPack Configuration
    set(CPACK_PACKAGE_NAME "${TARGET_NAME}")
    set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
    set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "${PROJECT_DESCRIPTION}")
    set(CPACK_PACKAGE_VENDOR "Minu-Park")

    if(APPLE)
        set(CPACK_GENERATOR "DragNDrop")
        set(CPACK_DMG_VOLUME_NAME "${TARGET_NAME}")
        set(CPACK_SYSTEM_NAME "macOS")
    elseif(WIN32)
        set(CPACK_GENERATOR "ZIP")
        set(CPACK_SYSTEM_NAME "win64")
    else()
        set(CPACK_GENERATOR "TGZ")
        set(CPACK_SYSTEM_NAME "linux")
    endif()

    include(CPack)
endmacro()
