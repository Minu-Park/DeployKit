# DeployKit.cmake
# Reusable deployment and bundling system for Qt-based cross-platform projects.

macro(deploykit_configure_bundling TARGET_NAME)
    # Parse arguments
    set(options)
    set(oneValueArgs MACOSX_ICON)
    set(multiValueArgs EXTRA_LIBS EXTRA_FILES LIBPATHS)
    cmake_parse_arguments(DEPLOY "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    message(STATUS "[DeployKit] Configuring deployment for target: ${TARGET_NAME}")

    # Set default install prefix to build/bundled if not set by user or defaults to /usr/local
    if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT OR CMAKE_INSTALL_PREFIX STREQUAL "/usr/local")
        set(CMAKE_INSTALL_PREFIX "${CMAKE_BINARY_DIR}/../bundled" CACHE PATH "Install path prefix" FORCE)
        message(STATUS "[DeployKit] Setting default CMAKE_INSTALL_PREFIX to: ${CMAKE_INSTALL_PREFIX}")
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
            BUNDLE DESTINATION .
            RUNTIME DESTINATION bin
        )

        # Copy extra libraries to the bundle Frameworks directory
        foreach(lib ${DEPLOY_EXTRA_LIBS})
            if(TARGET ${lib})
                install(TARGETS ${lib}
                    LIBRARY DESTINATION ${TARGET_NAME}.app/Contents/Frameworks
                    ARCHIVE DESTINATION ${TARGET_NAME}.app/Contents/Frameworks
                    RUNTIME DESTINATION ${TARGET_NAME}.app/Contents/Frameworks
                )
            else()
                if(EXISTS "${lib}")
                    install(FILES "${lib}"
                        DESTINATION ${TARGET_NAME}.app/Contents/Frameworks
                    )
                else()
                    # It might be a library name like kApi, GoApi, etc.
                    # We will copy it from link directories or skip if not found
                    message(STATUS "[DeployKit] Non-target dependency specified: ${lib}. Ensure it is copied or found by macdeployqt.")
                endif()
            endif()
        endforeach()

        # Copy pylon.framework to the bundle Frameworks directory if it exists
        if(EXISTS "/Library/Frameworks/pylon.framework")
            install(DIRECTORY "/Library/Frameworks/pylon.framework"
                DESTINATION ${TARGET_NAME}.app/Contents/Frameworks
                USE_SOURCE_PERMISSIONS
            )
        endif()

        # Execute macdeployqt as a post-install step
        if(MACDEPLOYQT_PATH)
            set(macdeployqt_libpaths "")
            foreach(path ${DEPLOY_LIBPATHS})
                list(APPEND macdeployqt_libpaths "-libpath=${path}")
            endforeach()

            install(CODE "
                get_filename_component(abs_prefix \"\${CMAKE_INSTALL_PREFIX}\" ABSOLUTE)
                message(STATUS \"[DeployKit] Packaging: Running macdeployqt on \${abs_prefix}/${TARGET_NAME}.app with libpaths: ${DEPLOY_LIBPATHS}...\")
                execute_process(
                    COMMAND \"${MACDEPLOYQT_PATH}\" \"\${abs_prefix}/${TARGET_NAME}.app\" ${macdeployqt_libpaths} -verbose=1
                    RESULT_VARIABLE deploy_res
                )
                if(NOT deploy_res EQUAL 0)
                    message(FATAL_ERROR \"[DeployKit] macdeployqt failed with exit code: \${deploy_res}\")
                endif()

                # Get runtime dependencies of target and copy them recursively
                message(STATUS \"[DeployKit] Packaging: Resolving runtime dependencies recursively...\")
                set(binaries_to_analyze 
                    \"\${abs_prefix}/${TARGET_NAME}.app/Contents/MacOS/${TARGET_NAME}\"
                    \"\${abs_prefix}/${TARGET_NAME}.app/Contents/Frameworks/libGraphicsEngine.dylib\"
                )
                set(copied_libs \"\")
                set(new_dependencies_found TRUE)
                
                while(new_dependencies_found)
                    set(new_dependencies_found FALSE)
                    
                    file(GET_RUNTIME_DEPENDENCIES
                        EXECUTABLES \${binaries_to_analyze}
                        RESOLVED_DEPENDENCIES_VAR resolved_deps
                        UNRESOLVED_DEPENDENCIES_VAR unresolved_deps
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
                            if(dep MATCHES \"pylon.framework\")
                                # pylon.framework is copied as a directory, skip individual files
                                continue()
                            endif()
                            
                            # Resolve real path in case it is a symlink
                            get_filename_component(real_dep \"\${dep}\" REALPATH)
                            
                            # Copy shared library file to Frameworks directory
                            file(INSTALL DESTINATION \"\${abs_prefix}/${TARGET_NAME}.app/Contents/Frameworks\"
                                TYPE SHARED_LIBRARY
                                FILES \"\${dep}\"
                            )
                            
                            # If symlink, copy the real file too
                            if(NOT \"\${dep}\" STREQUAL \"\${real_dep}\")
                                message(STATUS \"[DeployKit] Copying dependency symlink target: \${real_dep}\")
                                file(INSTALL DESTINATION \"\${abs_prefix}/${TARGET_NAME}.app/Contents/Frameworks\"
                                    TYPE SHARED_LIBRARY
                                    FILES \"\${real_dep}\"
                                )
                            endif()
                            
                            list(APPEND copied_libs \"\${dep_name}\")
                            list(APPEND binaries_to_analyze \"\${abs_prefix}/${TARGET_NAME}.app/Contents/Frameworks/\${dep_name}\")
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
                                
                                # Resolve real path in case it is a symlink
                                get_filename_component(real_found_path \"\${found_path}\" REALPATH)
                                
                                # Copy the file (this copies the symlink)
                                file(INSTALL DESTINATION \"\${abs_prefix}/${TARGET_NAME}.app/Contents/Frameworks\"
                                    TYPE SHARED_LIBRARY
                                    FILES \"\${found_path}\"
                                )
                                
                                # If symlink, copy the real file too
                                if(NOT \"\${found_path}\" STREQUAL \"\${real_found_path}\")
                                    message(STATUS \"[DeployKit] Copying unresolved symlink target: \${real_found_path}\")
                                    file(INSTALL DESTINATION \"\${abs_prefix}/${TARGET_NAME}.app/Contents/Frameworks\"
                                        TYPE SHARED_LIBRARY
                                        FILES \"\${real_found_path}\"
                                    )
                                endif()
                                
                                list(APPEND copied_libs \"\${dep_name}\")
                                list(APPEND binaries_to_analyze \"\${abs_prefix}/${TARGET_NAME}.app/Contents/Frameworks/\${dep_name}\")
                                set(new_dependencies_found TRUE)
                            else()
                                message(WARNING \"[DeployKit] Unresolved dependency not found in search paths: \${dep}\")
                            endif()
                        endif()
                    endforeach()
                endwhile()
            ")
        endif()

    elseif(WIN32)
        # 2. Windows Deployment
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
            RUNTIME DESTINATION .
        )

        # Copy extra libraries to root (next to .exe)
        foreach(lib ${DEPLOY_EXTRA_LIBS})
            if(TARGET ${lib})
                install(TARGETS ${lib}
                    RUNTIME DESTINATION .
                    LIBRARY DESTINATION .
                )
            else()
                if(EXISTS "${lib}")
                    install(FILES "${lib}"
                        DESTINATION .
                    )
                else()
                    message(STATUS "[DeployKit] Non-target dependency specified: ${lib}. Ensure it is copied next to the executable.")
                endif()
            endif()
        endforeach()

        # Execute windeployqt as a post-install step
        if(WINDEPLOYQT_PATH)
            install(CODE "
                message(STATUS \"[DeployKit] Packaging: Running windeployqt on \${CMAKE_INSTALL_PREFIX}/${TARGET_NAME}.exe...\")
                execute_process(
                    COMMAND \"${WINDEPLOYQT_PATH}\" \"\${CMAKE_INSTALL_PREFIX}/${TARGET_NAME}.exe\" --no-compiler-runtime --verbose=1
                    RESULT_VARIABLE deploy_res
                )
                if(NOT deploy_res EQUAL 0)
                    message(FATAL_ERROR \"[DeployKit] windeployqt failed with exit code: \${deploy_res}\")
                endif()
            ")
        endif()

    else()
        # 3. Linux Deployment (Standard RPATH layout)
        install(TARGETS ${TARGET_NAME}
            RUNTIME DESTINATION bin
        )

        # Install extra libraries to lib/
        foreach(lib ${DEPLOY_EXTRA_LIBS})
            if(TARGET ${lib})
                install(TARGETS ${lib}
                    LIBRARY DESTINATION lib
                    RUNTIME DESTINATION bin
                )
            else()
                if(EXISTS "${lib}")
                    install(FILES "${lib}"
                        DESTINATION lib
                    )
                endif()
            endif()
        endforeach()

        # Set RPATH for the executable to find libraries in lib/
        set_target_properties(${TARGET_NAME} PROPERTIES
            INSTALL_RPATH "$ORIGIN/../lib"
        )
        message(STATUS "[DeployKit] Linux RPATH configured to \$ORIGIN/../lib")
    endif()

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
