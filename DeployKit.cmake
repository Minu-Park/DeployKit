# DeployKit.cmake
# Reusable deployment and bundling system for Qt-based cross-platform projects.

set(DEPLOYKIT_MODULE_DIR "${CMAKE_CURRENT_LIST_DIR}")

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
    set(oneValueArgs
        MACOSX_ICON
        DESTINATION
        IFW_COMPONENT_MANIFEST
        VS_BUILD_TOOLS_BOOTSTRAPPER
        VS_BUILD_TOOLS_MSVC_COMPONENT
        VS_BUILD_TOOLS_SDK_COMPONENT
    )
    set(multiValueArgs EXTRA_LIBS EXTRA_FILES LIBPATHS ANALYZE_BINARIES)
    cmake_parse_arguments(DEPLOY "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    message(STATUS "[DeployKit] Configuring deployment for target: ${TARGET_NAME}")

    if(CPACK_IFW_ROOT)
        file(TO_CMAKE_PATH "${CPACK_IFW_ROOT}" deploykit_ifw_root_normalized)
        set(CPACK_IFW_ROOT "${deploykit_ifw_root_normalized}" CACHE PATH
            "Qt Installer Framework root used by CPack IFW." FORCE)
    endif()

    get_target_property(deploykit_target_output_name ${TARGET_NAME} OUTPUT_NAME)
    if(NOT deploykit_target_output_name)
        set(deploykit_target_output_name "${TARGET_NAME}")
    endif()

    set(deploykit_ifw_components "")
    if(WIN32 AND DEPLOY_IFW_COMPONENT_MANIFEST)
        if(NOT EXISTS "${DEPLOY_IFW_COMPONENT_MANIFEST}")
            message(FATAL_ERROR
                "[DeployKit] IFW component manifest not found: ${DEPLOY_IFW_COMPONENT_MANIFEST}"
            )
        endif()
        include("${DEPLOY_IFW_COMPONENT_MANIFEST}")
        if(NOT DEPLOYKIT_IFW_COMPONENTS OR NOT DEPLOYKIT_IFW_DEFAULT_COMPONENT)
            message(FATAL_ERROR
                "[DeployKit] IFW component manifest must define DEPLOYKIT_IFW_COMPONENTS and DEPLOYKIT_IFW_DEFAULT_COMPONENT."
            )
        endif()
        list(FIND DEPLOYKIT_IFW_COMPONENTS "${DEPLOYKIT_IFW_DEFAULT_COMPONENT}" deploykit_default_component_index)
        if(deploykit_default_component_index EQUAL -1)
            message(FATAL_ERROR
                "[DeployKit] Default IFW component '${DEPLOYKIT_IFW_DEFAULT_COMPONENT}' is not registered."
            )
        endif()
        set(deploykit_ifw_components ${DEPLOYKIT_IFW_COMPONENTS})
        find_program(deploykit_ifw_archivegen
            NAMES archivegen archivegen.exe
            HINTS "${CPACK_IFW_ROOT}/bin"
            DOC "Qt IFW archive generator used for reusable component archives."
        )
        foreach(deploykit_ifw_component IN LISTS deploykit_ifw_components)
            set(deploykit_cache_var "DEPLOYKIT_IFW_COMPONENT_${deploykit_ifw_component}_CACHE_ARCHIVE")
            if(${deploykit_cache_var} AND NOT deploykit_ifw_archivegen)
                message(FATAL_ERROR
                    "[DeployKit] archivegen is required by cached IFW component '${deploykit_ifw_component}'."
                )
            endif()
        endforeach()
        set(deploykit_ifw_component_script "${CMAKE_CURRENT_BINARY_DIR}/deploykit_ifw_component_install.cmake")
        set(deploykit_ifw_runtime_component_script
            "${CMAKE_CURRENT_BINARY_DIR}/deploykit_ifw_runtime_component.qs"
        )
        configure_file(
            "${DEPLOYKIT_MODULE_DIR}/ifw_component_install.cmake.in"
            "${deploykit_ifw_component_script}"
            @ONLY
        )
        configure_file(
            "${DEPLOYKIT_MODULE_DIR}/ifw_runtime_component.qs.in"
            "${deploykit_ifw_runtime_component_script}"
            @ONLY
        )
        foreach(deploykit_ifw_component IN LISTS deploykit_ifw_components)
            install(SCRIPT "${deploykit_ifw_component_script}"
                COMPONENT "${deploykit_ifw_component}"
            )
        endforeach()
        if(DEPLOYKIT_IFW_UPDATE_COMPONENTS)
            list(JOIN DEPLOYKIT_IFW_UPDATE_COMPONENTS "\n" deploykit_ifw_update_component_lines)
            file(WRITE "${CMAKE_BINARY_DIR}/ifw-update-components.txt"
                "${deploykit_ifw_update_component_lines}\n"
            )
        endif()
    endif()

    _deploykit_collect_target_runtime_paths(${TARGET_NAME} ${TARGET_NAME} deploykit_auto_libpaths)
    list(APPEND DEPLOY_LIBPATHS ${deploykit_auto_libpaths})
    list(REMOVE_DUPLICATES DEPLOY_LIBPATHS)

    # Keep generated bundles in the binary tree on every platform. This preserves
    # out-of-source build isolation and avoids writing artifacts into a read-only
    # or shared source checkout.
    if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT OR 
       CMAKE_INSTALL_PREFIX STREQUAL "/usr/local" OR 
       CMAKE_INSTALL_PREFIX MATCHES "^[a-zA-Z]:/Program Files")
        set(deploykit_default_install_prefix "${CMAKE_BINARY_DIR}/bundle")
        set(CMAKE_INSTALL_PREFIX "${deploykit_default_install_prefix}" CACHE PATH "Install path prefix" FORCE)
        message(STATUS "[DeployKit] Setting default CMAKE_INSTALL_PREFIX to: ${CMAKE_INSTALL_PREFIX}")
    endif()

    if(DEFINED DEPLOY_DESTINATION)
        set(deploykit_bundle_destination "${DEPLOY_DESTINATION}")
    else()
        set(deploykit_bundle_destination "$<CONFIG>")
    endif()

    if(deploykit_bundle_destination STREQUAL "" OR deploykit_bundle_destination STREQUAL ".")
        set(deploykit_bundle_dest_path "")
    else()
        set(deploykit_bundle_dest_path "${deploykit_bundle_destination}/")
    endif()

    if(APPLE)
        set(deploykit_installed_target_path "${CMAKE_INSTALL_PREFIX}/${deploykit_bundle_dest_path}${deploykit_target_output_name}.app")
    else()
        set(deploykit_installed_target_path "${CMAKE_INSTALL_PREFIX}/${deploykit_bundle_dest_path}${deploykit_target_output_name}${CMAKE_EXECUTABLE_SUFFIX}")
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
                if(APPLE)
                    execute_process(COMMAND xattr -rc \"\${deploykit_bundle_prefix}\" ERROR_QUIET)
                endif()
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

        find_program(VSWHERE_PATH vswhere
            HINTS "C:/Program Files (x86)/Microsoft Visual Studio/Installer"
                  "C:/Program Files/Microsoft Visual Studio/Installer"
                  "$ENV{ProgramFiles\(x86\)}/Microsoft Visual Studio/Installer"
                  "$ENV{ProgramFiles}/Microsoft Visual Studio/Installer"
            DOC "Path to vswhere tool"
        )
        if(VSWHERE_PATH)
            message(STATUS "[DeployKit] Found vswhere: ${VSWHERE_PATH}")
        else()
            message(WARNING "[DeployKit] vswhere not found! Visual Studio path auto-detection might fail.")
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

        # Include MSVC runtime libraries (vcruntime140.dll, msvcp140.dll, etc.) in the package
        if(WIN32)
            set(CMAKE_INSTALL_OPENMP_LIBRARIES ON)
            set(CMAKE_INSTALL_SYSTEM_RUNTIME_DESTINATION "${deploykit_bundle_destination}")
            include(InstallRequiredSystemLibraries)
        endif()

        if(deploykit_bundle_destination MATCHES "\\$<CONFIG>")
            set(install_time_dest "\${CMAKE_INSTALL_CONFIG_NAME}")
        else()
            set(install_time_dest "${deploykit_bundle_destination}")
        endif()

        # Execute windeployqt as a post-install step
        if(WINDEPLOYQT_PATH)
            install(CODE "
                if(NOT DEFINED ENV{VCINSTALLDIR} AND \"${VSWHERE_PATH}\")
                    execute_process(
                        COMMAND \"${VSWHERE_PATH}\" -latest -products * -property installationPath
                        OUTPUT_VARIABLE vs_install_path
                        OUTPUT_STRIP_TRAILING_WHITESPACE
                    )
                    if(vs_install_path)
                        string(REPLACE \"/\" \"\\\\\" native_vc_dir \"\${vs_install_path}/VC/\")
                        set(ENV{VCINSTALLDIR} \"\${native_vc_dir}\")
                        message(STATUS \"[DeployKit] Auto-detected VCINSTALLDIR: \$ENV{VCINSTALLDIR}\")
                    endif()
                endif()

                get_filename_component(abs_prefix \"\${CMAKE_INSTALL_PREFIX}\" ABSOLUTE)
                set(dest_sub \"${install_time_dest}\")
                if(dest_sub STREQUAL \"\" OR dest_sub STREQUAL \".\")
                    set(bundle_prefix \"\${abs_prefix}\")
                else()
                    set(bundle_prefix \"\${abs_prefix}/\${dest_sub}\")
                endif()
                message(STATUS \"[DeployKit] Packaging: Running windeployqt on \${bundle_prefix}/${TARGET_NAME}.exe...\")
                execute_process(
                    COMMAND \"${WINDEPLOYQT_PATH}\" \"\${bundle_prefix}/${TARGET_NAME}.exe\" --no-translations --verbose=1
                    RESULT_VARIABLE deploy_res
                )
                if(NOT deploy_res EQUAL 0)
                    message(FATAL_ERROR \"[DeployKit] windeployqt failed with exit code: \${deploy_res}\")
                endif()
            ")
        endif()

        install(CODE "
            get_filename_component(abs_prefix \"\${CMAKE_INSTALL_PREFIX}\" ABSOLUTE)
            set(dest_sub \"${install_time_dest}\")
            if(dest_sub STREQUAL \"\" OR dest_sub STREQUAL \".\")
                set(bundle_prefix \"\${abs_prefix}\")
            else()
                set(bundle_prefix \"\${abs_prefix}/\${dest_sub}\")
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
    if(NOT DEFINED CPACK_PACKAGE_NAME)
        set(CPACK_PACKAGE_NAME "${TARGET_NAME}")
    endif()
    if(NOT DEFINED CPACK_PACKAGE_VERSION)
        set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
    endif()
    if(NOT DEFINED CPACK_PACKAGE_DESCRIPTION_SUMMARY)
        set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "${PROJECT_DESCRIPTION}")
    endif()
    if(NOT DEFINED CPACK_PACKAGE_VENDOR)
        set(CPACK_PACKAGE_VENDOR "Minu-Park")
    endif()

    if(APPLE)
        set(CPACK_GENERATOR "DragNDrop")
        set(CPACK_DMG_VOLUME_NAME "${TARGET_NAME}")
        set(CPACK_SYSTEM_NAME "macOS")
        if(NOT DEFINED CPACK_INSTALL_CMAKE_PROJECTS)
            set(CPACK_INSTALL_CMAKE_PROJECTS "")
        endif()
        if(NOT DEFINED CPACK_INSTALL_SCRIPTS)
            set(deploykit_macos_cpack_install_script
                "${CMAKE_CURRENT_BINARY_DIR}/DeployKit${TARGET_NAME}MacDmgInstall.cmake"
            )
            file(WRITE "${deploykit_macos_cpack_install_script}" "
set(deploykit_source_prefix \"${CMAKE_INSTALL_PREFIX}\")
set(deploykit_target_output_name \"${deploykit_target_output_name}\")
set(deploykit_stage_prefix \"\${CMAKE_INSTALL_PREFIX}\")

set(deploykit_config_candidates \"\")
if(DEFINED CPACK_BUILD_CONFIG AND NOT CPACK_BUILD_CONFIG STREQUAL \"\")
    list(APPEND deploykit_config_candidates \"\${CPACK_BUILD_CONFIG}\")
endif()
if(DEFINED CMAKE_INSTALL_CONFIG_NAME AND NOT CMAKE_INSTALL_CONFIG_NAME STREQUAL \"\")
    list(APPEND deploykit_config_candidates \"\${CMAKE_INSTALL_CONFIG_NAME}\")
endif()
list(APPEND deploykit_config_candidates Release Debug RelWithDebInfo MinSizeRel)
list(REMOVE_DUPLICATES deploykit_config_candidates)

set(deploykit_source_app \"\")
foreach(deploykit_config_name IN LISTS deploykit_config_candidates)
    set(deploykit_candidate \"\${deploykit_source_prefix}/\${deploykit_config_name}/\${deploykit_target_output_name}.app\")
    if(EXISTS \"\${deploykit_candidate}\")
        set(deploykit_source_app \"\${deploykit_candidate}\")
        break()
    endif()
endforeach()

if(deploykit_source_app STREQUAL \"\")
    message(FATAL_ERROR \"[DeployKit] Bundled \${deploykit_target_output_name}.app not found under \${deploykit_source_prefix}/<Config>.\")
endif()

file(REMOVE_RECURSE \"\${deploykit_stage_prefix}/\${deploykit_target_output_name}.app\")
file(COPY \"\${deploykit_source_app}\" DESTINATION \"\${deploykit_stage_prefix}\")
")
            set(CPACK_INSTALL_SCRIPTS "${deploykit_macos_cpack_install_script}")
        endif()
    elseif(WIN32)
        if(NOT DEFINED CPACK_GENERATOR)
            set(CPACK_GENERATOR "IFW")
        endif()
        set(CPACK_SYSTEM_NAME "win64")

        if(CPACK_GENERATOR STREQUAL "IFW")
            # Enable CMake project install components instead of monolithic directory install
            set(CPACK_INSTALL_CMAKE_PROJECTS "${CMAKE_BINARY_DIR};${TARGET_NAME};ALL;/")
            unset(CPACK_INSTALLED_DIRECTORIES CACHE)
            unset(CPACK_INSTALLED_DIRECTORIES)

            # Core package metadata overrides
            set(CPACK_IFW_PACKAGE_TITLE "Basler Playground")
            set(CPACK_IFW_PACKAGE_PUBLISHER "Basler Korea Inc.")
            set(CPACK_IFW_PRODUCT_URL "https://github.com/minu-park/Playground")

            # Custom stylesheet for styling and dark mode fix
            set(deploykit_qss "${DEPLOYKIT_MODULE_DIR}/installer_style.qss")
            if(EXISTS "${deploykit_qss}")
                set(CPACK_IFW_PACKAGE_STYLE_SHEET "${deploykit_qss}")
            endif()

            # Layout and visual styles to hide classical sidebar and modernize layout
            set(CPACK_IFW_PACKAGE_WIZARD_STYLE "Modern")
            set(CPACK_IFW_PACKAGE_WIZARD_SHOW_PAGE_LIST "OFF")

            # Visual logo branding (scaled for installer header)
            set(deploykit_logo "${DEPLOYKIT_MODULE_DIR}/installer_logo.png")
            if(EXISTS "${deploykit_logo}")
                set(CPACK_IFW_PACKAGE_LOGO "${deploykit_logo}")
            endif()

            # Register extra Qt resources (QRC) containing brand fonts and icons
            set(deploykit_qrc "${CMAKE_SOURCE_DIR}/modules/Resources/Resources.qrc")
            if(EXISTS "${deploykit_qrc}")
                set(CPACK_IFW_PACKAGE_RESOURCES "${deploykit_qrc}")
            endif()

            # Generate controller.qs to handle dynamic UI behavior (like settings button hiding)
            set(deploykit_control_script "${CMAKE_CURRENT_BINARY_DIR}/controller.qs")
            configure_file(
                "${DEPLOYKIT_MODULE_DIR}/controller.qs.in"
                "${deploykit_control_script}"
                @ONLY
            )
            set(CPACK_IFW_PACKAGE_CONTROL_SCRIPT "${deploykit_control_script}")

            # Resolve AppIcon path
            set(deploykit_icon_path "${CMAKE_SOURCE_DIR}/modules/Resources/AppIcons/AppIcon.ico")
            if(EXISTS "${deploykit_icon_path}")
                set(CPACK_IFW_PACKAGE_ICON "${deploykit_icon_path}")
                set(deploykit_png_icon_path "${CMAKE_SOURCE_DIR}/modules/Resources/AppIcons/AppIcon.png")
                if(EXISTS "${deploykit_png_icon_path}")
                    set(CPACK_IFW_PACKAGE_WINDOW_ICON "${deploykit_png_icon_path}")
                endif()
            endif()

            # Post-install auto-start configuration (Run on Finish page)
            # Use powershell Start-Process with -WorkingDirectory to force correct working directory (resolves DLL loading issues and forward slash path space errors)
            set(CPACK_IFW_PACKAGE_RUN_PROGRAM "powershell.exe")
            set(CPACK_IFW_PACKAGE_RUN_PROGRAM_ARGUMENTS "-NoProfile" "-Command" "Start-Process -FilePath '@TargetDir@/${deploykit_target_output_name}${CMAKE_EXECUTABLE_SUFFIX}' -WorkingDirectory '@TargetDir@'")
            set(CPACK_IFW_PACKAGE_RUN_PROGRAM_DESCRIPTION "Run Basler Playground")

            # Set variables for shortcut script template
            set(DEPLOYKIT_TARGET_EXE "${deploykit_target_output_name}${CMAKE_EXECUTABLE_SUFFIX}")
            set(DEPLOYKIT_TARGET_NAME "Basler Playground")
            # Preserve QtIFW runtime placeholders through configure_file(@ONLY).
            set(DEPLOYKIT_IFW_TARGET_DIR "@TargetDir@")
            set(DEPLOYKIT_IFW_START_MENU_DIR "@StartMenuDir@")
            set(DEPLOYKIT_IFW_DESKTOP_DIR "@DesktopDir@")
            if(DEFINED CPACK_CREATE_DESKTOP_LINKS OR DEFINED deploykit_create_desktop_links)
                set(DEPLOYKIT_CREATE_DESKTOP_LINKS "ON")
            else()
                set(DEPLOYKIT_CREATE_DESKTOP_LINKS "")
            endif()

            # Generate installscript.qs for the main application component.
            set(deploykit_script_out "${CMAKE_CURRENT_BINARY_DIR}/installscript.qs")
            configure_file(
                "${DEPLOYKIT_MODULE_DIR}/installscript.qs.in"
                "${deploykit_script_out}"
                @ONLY
            )

            # Package the already-validated bundle as an explicit component. CPack's
            # reserved Unspecified component is always hidden by CMake.
            if(NOT deploykit_ifw_components)
                install(CODE "
                    if(CMAKE_INSTALL_COMPONENT STREQUAL \"Playground\")
                        set(deploykit_bundle_source \"${CMAKE_BINARY_DIR}/bundle/\${CMAKE_INSTALL_CONFIG_NAME}\")
                        if(NOT EXISTS \"\${deploykit_bundle_source}/${deploykit_target_output_name}${CMAKE_EXECUTABLE_SUFFIX}\")
                            message(FATAL_ERROR \"[DeployKit] Bundle is missing: \${deploykit_bundle_source}\")
                        endif()
                        file(COPY \"\${deploykit_bundle_source}/\" DESTINATION \"\${CMAKE_INSTALL_PREFIX}\")
                    endif()
                " COMPONENT Playground)
            endif()

            # Generate separate prerequisite scripts when the Build Tools bootstrapper is available.
            set(deploykit_vs_bootstrapper "${DEPLOY_VS_BUILD_TOOLS_BOOTSTRAPPER}")
            if(EXISTS "${deploykit_vs_bootstrapper}")
                set(DEPLOYKIT_MSVC_COMPONENT_ID "${DEPLOY_VS_BUILD_TOOLS_MSVC_COMPONENT}")
                set(DEPLOYKIT_WINDOWS_SDK_COMPONENT_ID "${DEPLOY_VS_BUILD_TOOLS_SDK_COMPONENT}")

                install(FILES "${deploykit_vs_bootstrapper}"
                    DESTINATION ${deploykit_bundle_destination}
                    COMPONENT Unspecified
                )

                set(deploykit_msvc_script_out "${CMAKE_CURRENT_BINARY_DIR}/msvc_installscript.qs")
                configure_file(
                    "${DEPLOYKIT_MODULE_DIR}/msvc_installscript.qs.in"
                    "${deploykit_msvc_script_out}"
                    @ONLY
                )

                set(deploykit_windows_sdk_script_out "${CMAKE_CURRENT_BINARY_DIR}/windows_sdk_installscript.qs")
                configure_file(
                    "${DEPLOYKIT_MODULE_DIR}/windows_sdk_installscript.qs.in"
                    "${deploykit_windows_sdk_script_out}"
                    @ONLY
                )

                # CPack omits components with no payload, so give each script-only
                # prerequisite a tiny owned marker file. The bootstrapper itself is
                # already part of the required Playground bundle.
                set(deploykit_msvc_marker "${CMAKE_CURRENT_BINARY_DIR}/msvc-build-tools.component")
                set(deploykit_windows_sdk_marker "${CMAKE_CURRENT_BINARY_DIR}/windows-sdk.component")
                file(WRITE "${deploykit_msvc_marker}" "MSVC C++ Build Tools prerequisite\n")
                file(WRITE "${deploykit_windows_sdk_marker}" "Windows SDK prerequisite\n")
                install(FILES "${deploykit_msvc_marker}"
                    DESTINATION "Resources/Installer"
                    COMPONENT MSVCBuildTools
                )
                install(FILES "${deploykit_windows_sdk_marker}"
                    DESTINATION "Resources/Installer"
                    COMPONENT WindowsSDK
                )
            endif()
        else()
            # NSIS Fallback
            set(deploykit_icon_path "${CMAKE_SOURCE_DIR}/modules/Resources/AppIcons/AppIcon.ico")
            if(EXISTS "${deploykit_icon_path}")
                file(TO_NATIVE_PATH "${deploykit_icon_path}" deploykit_icon_native)
                string(REPLACE "\\" "\\\\" deploykit_icon_native_esc "${deploykit_icon_native}")
                set(CPACK_NSIS_MUI_ICON "${deploykit_icon_native_esc}")
                set(CPACK_NSIS_MUI_UNIICON "${deploykit_icon_native_esc}")
            endif()

            if(NOT DEFINED CPACK_NSIS_MENU_LINKS)
                set(CPACK_NSIS_MENU_LINKS "${deploykit_target_output_name}${CMAKE_EXECUTABLE_SUFFIX}" "${CPACK_PACKAGE_NAME}")
            endif()
            if(NOT DEFINED CPACK_CREATE_DESKTOP_LINKS)
                set(CPACK_CREATE_DESKTOP_LINKS "${deploykit_target_output_name}${CMAKE_EXECUTABLE_SUFFIX}")
            endif()

            if(NOT DEFINED CPACK_NSIS_DEFINES)
                set(CPACK_NSIS_DEFINES "
                  !define MUI_FINISHPAGE_RUN
                  !define MUI_FINISHPAGE_RUN_FUNCTION Run${TARGET_NAME}Custom

                  Function Run${TARGET_NAME}Custom
                    SetOutPath \\\"\$INSTDIR\\\"
                    Exec \\\"\$INSTDIR\\\\${deploykit_target_output_name}${CMAKE_EXECUTABLE_SUFFIX}\\\"
                  FunctionEnd
                ")
            endif()
        endif()
    else()
        set(CPACK_GENERATOR "TGZ")
        set(CPACK_SYSTEM_NAME "linux")
    endif()


    # Define and configure components before including CPack so their metadata is
    # serialized into CPackConfig.cmake.
    if(WIN32 AND (NOT DEFINED CPACK_GENERATOR OR CPACK_GENERATOR STREQUAL "IFW"))
        include(CPackComponent)
        include(CPackIFW)
        set(CPACK_COMPONENTS_GROUPING IGNORE)

        if(deploykit_ifw_components)
            set(CPACK_COMPONENTS_ALL ${deploykit_ifw_components})
        else()
            set(CPACK_COMPONENTS_ALL Playground)
        endif()
        if(EXISTS "${deploykit_vs_bootstrapper}")
            list(APPEND CPACK_COMPONENTS_ALL MSVCBuildTools WindowsSDK)
        endif()

        if(deploykit_ifw_components)
            foreach(deploykit_ifw_component IN LISTS deploykit_ifw_components)
                set(deploykit_display_var "DEPLOYKIT_IFW_COMPONENT_${deploykit_ifw_component}_DISPLAY_NAME")
                set(deploykit_description_var "DEPLOYKIT_IFW_COMPONENT_${deploykit_ifw_component}_DESCRIPTION")
                set(deploykit_version_var "DEPLOYKIT_IFW_COMPONENT_${deploykit_ifw_component}_VERSION")
                set(deploykit_dependencies_var "DEPLOYKIT_IFW_COMPONENT_${deploykit_ifw_component}_DEPENDENCIES")
                set(deploykit_replaces_var "DEPLOYKIT_IFW_COMPONENT_${deploykit_ifw_component}_REPLACES")
                set(deploykit_required_var "DEPLOYKIT_IFW_COMPONENT_${deploykit_ifw_component}_REQUIRED")
                set(deploykit_hidden_var "DEPLOYKIT_IFW_COMPONENT_${deploykit_ifw_component}_HIDDEN")
                set(deploykit_default_var "DEPLOYKIT_IFW_COMPONENT_${deploykit_ifw_component}_DEFAULT")
                set(deploykit_priority_var "DEPLOYKIT_IFW_COMPONENT_${deploykit_ifw_component}_SORTING_PRIORITY")
                set(deploykit_hide_installer_var "DEPLOYKIT_IFW_COMPONENT_${deploykit_ifw_component}_HIDE_DURING_INSTALL")

                set(deploykit_cpack_component_args)
                if(${deploykit_required_var})
                    list(APPEND deploykit_cpack_component_args REQUIRED)
                endif()
                if(${deploykit_hidden_var})
                    list(APPEND deploykit_cpack_component_args HIDDEN)
                endif()
                cpack_add_component(${deploykit_ifw_component}
                    DISPLAY_NAME "${${deploykit_display_var}}"
                    DESCRIPTION "${${deploykit_description_var}}"
                    ${deploykit_cpack_component_args}
                )

                set(deploykit_ifw_component_args
                    VERSION "${${deploykit_version_var}}"
                    SORTING_PRIORITY "${${deploykit_priority_var}}"
                )
                if(${deploykit_required_var})
                    list(APPEND deploykit_ifw_component_args FORCED_INSTALLATION)
                endif()
                if(${deploykit_hidden_var})
                    list(APPEND deploykit_ifw_component_args VIRTUAL)
                endif()
                if(DEFINED ${deploykit_default_var})
                    list(APPEND deploykit_ifw_component_args DEFAULT "${${deploykit_default_var}}")
                endif()
                if(${deploykit_dependencies_var})
                    list(APPEND deploykit_ifw_component_args DEPENDS ${${deploykit_dependencies_var}})
                endif()
                if(${deploykit_replaces_var})
                    list(APPEND deploykit_ifw_component_args REPLACES ${${deploykit_replaces_var}})
                endif()
                if(deploykit_ifw_component STREQUAL DEPLOYKIT_IFW_SHORTCUT_COMPONENT)
                    list(APPEND deploykit_ifw_component_args SCRIPT "${deploykit_script_out}")
                elseif(${deploykit_hide_installer_var})
                    list(APPEND deploykit_ifw_component_args SCRIPT "${deploykit_ifw_runtime_component_script}")
                endif()
                cpack_ifw_configure_component(${deploykit_ifw_component}
                    ${deploykit_ifw_component_args}
                )
            endforeach()
        else()
            cpack_add_component(Playground
                DISPLAY_NAME "Basler Playground"
                DESCRIPTION "Basler Playground main application and dependencies"
                REQUIRED
            )
            cpack_ifw_configure_component(Playground
                SCRIPT "${deploykit_script_out}"
                FORCED_INSTALLATION
                SORTING_PRIORITY 100
            )
        endif()

        if(EXISTS "${deploykit_vs_bootstrapper}")
            cpack_add_component_group(DevelopmentPrerequisites
                DISPLAY_NAME "Development prerequisites"
                DESCRIPTION "Optional compiler components used by real-time script compilation"
                EXPANDED
            )
            cpack_ifw_configure_component_group(DevelopmentPrerequisites
                SORTING_PRIORITY 50
            )

            cpack_add_component(MSVCBuildTools
                DISPLAY_NAME "MSVC C++ Build Tools"
                DESCRIPTION "Microsoft C++ x64/x86 compiler and toolchain"
                GROUP DevelopmentPrerequisites
            )
            cpack_ifw_configure_component(MSVCBuildTools
                SCRIPT "${deploykit_msvc_script_out}"
                SORTING_PRIORITY 40
                DEPENDS ${DEPLOYKIT_IFW_PREREQUISITE_PAYLOAD_COMPONENT}
            )

            cpack_add_component(WindowsSDK
                DISPLAY_NAME "Windows SDK"
                DESCRIPTION "Windows headers and x64 libraries required for compilation"
                GROUP DevelopmentPrerequisites
            )
            cpack_ifw_configure_component(WindowsSDK
                SCRIPT "${deploykit_windows_sdk_script_out}"
                SORTING_PRIORITY 30
                DEPENDS ${DEPLOYKIT_IFW_PREREQUISITE_PAYLOAD_COMPONENT}
            )
        endif()
    endif()

    include(CPack)
endmacro()
