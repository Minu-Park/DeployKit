# DeployKit.cmake
# Reusable deployment and bundling system for Qt-based cross-platform projects.

macro(deploykit_configure_bundling TARGET_NAME)
    # Parse arguments
    set(options)
    set(oneValueArgs MACOSX_ICON)
    set(multiValueArgs EXTRA_LIBS EXTRA_FILES)
    cmake_parse_arguments(DEPLOY "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    message(STATUS "[DeployKit] Configuring deployment for target: ${TARGET_NAME}")

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

        # Execute macdeployqt as a post-install step
        if(MACDEPLOYQT_PATH)
            install(CODE "
                message(STATUS \"[DeployKit] Packaging: Running macdeployqt on \${CMAKE_INSTALL_PREFIX}/${TARGET_NAME}.app...\")
                execute_process(
                    COMMAND \"${MACDEPLOYQT_PATH}\" \"\${CMAKE_INSTALL_PREFIX}/${TARGET_NAME}.app\" -verbose=1
                    RESULT_VARIABLE deploy_res
                )
                if(NOT deploy_res EQUAL 0)
                    message(FATAL_ERROR \"[DeployKit] macdeployqt failed with exit code: \${deploy_res}\")
                endif()
            " COMPONENT Runtime)
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
            " COMPONENT Runtime)
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
        set(CPACK_GENERATOR "DMG")
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
