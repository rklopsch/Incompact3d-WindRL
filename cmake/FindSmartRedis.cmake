# - Find the SmartRedis library
find_path(SMARTREDIS_INCLUDE_DIR NAMES smartredis.hpp
          PATHS ${CMAKE_SOURCE_DIR}/smartredis/build/install/include)

find_library(SMARTREDIS_LIBRARY NAMES smartredis
     PATHS ${CMAKE_SOURCE_DIR}/smartredis/build/install/lib
       ${CMAKE_SOURCE_DIR}/smartredis/build/install/lib64)

find_library(SMARTREDIS_FORTRAN_LIBRARY NAMES smartredis-fortran
     PATHS ${CMAKE_SOURCE_DIR}/smartredis/build/install/lib
       ${CMAKE_SOURCE_DIR}/smartredis/build/install/lib64)

if (SMARTREDIS_INCLUDE_DIR AND SMARTREDIS_LIBRARY AND SMARTREDIS_FORTRAN_LIBRARY)
  set(SMARTREDIS_FOUND TRUE)
  set(SMARTREDIS_INCLUDE_DIRS ${SMARTREDIS_INCLUDE_DIR})
  set(SMARTREDIS_LIBRARIES ${SMARTREDIS_LIBRARY} ${SMARTREDIS_FORTRAN_LIBRARY})
  get_filename_component(SMARTREDIS_LIBRARY_DIR ${SMARTREDIS_LIBRARY} DIRECTORY)
else()
  message(STATUS "SmartRedis not found, attempting to download and build...")

  file(MAKE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/smartredis-build)

  if(NOT EXISTS ${CMAKE_CURRENT_BINARY_DIR}/smartredis-build/smartredis)
    execute_process(
      COMMAND git clone https://github.com/CrayLabs/SmartRedis.git smartredis
      RESULT_VARIABLE result
      WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/smartredis-build
    )
    if(result)
      message(FATAL_ERROR "Git clone for SmartRedis failed: ${result}")
    else()
      message(STATUS "Git clone for SmartRedis completed (${result}).")
    endif()
  endif()

    execute_process(
    COMMAND git checkout v0.5.3
    RESULT_VARIABLE result
    WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/smartredis-build/smartredis
  )
  if(result)
    message(FATAL_ERROR "Checkout of SmartRedis v0.5.3 failed: ${result}")
  endif()

  execute_process(
    COMMAND make lib-with-fortran SR_PYTHON=OFF
    RESULT_VARIABLE result
    WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/smartredis-build/smartredis
  )
  if(result)
    message(FATAL_ERROR "Build step for SmartRedis failed: ${result}")
  else()
    message(STATUS "Build step for SmartRedis completed (${result}).")
  endif()

  set(SMARTREDIS_INCLUDE_DIR ${CMAKE_CURRENT_BINARY_DIR}/smartredis-build/smartredis/install/include)
  find_library(SMARTREDIS_LIBRARY NAMES smartredis
    PATHS ${CMAKE_CURRENT_BINARY_DIR}/smartredis-build/smartredis/install/lib
          ${CMAKE_CURRENT_BINARY_DIR}/smartredis-build/smartredis/install/lib64 NO_DEFAULT_PATH)
  find_library(SMARTREDIS_FORTRAN_LIBRARY NAMES smartredis-fortran
    PATHS ${CMAKE_CURRENT_BINARY_DIR}/smartredis-build/smartredis/install/lib
          ${CMAKE_CURRENT_BINARY_DIR}/smartredis-build/smartredis/install/lib64 NO_DEFAULT_PATH)
  if(NOT SMARTREDIS_LIBRARY OR NOT SMARTREDIS_FORTRAN_LIBRARY)
    message(FATAL_ERROR "SmartRedis build did not install the required C++ and Fortran libraries")
  endif()
  set(SMARTREDIS_FOUND TRUE)
  set(SMARTREDIS_INCLUDE_DIRS ${SMARTREDIS_INCLUDE_DIR})
  set(SMARTREDIS_LIBRARIES ${SMARTREDIS_LIBRARY} ${SMARTREDIS_FORTRAN_LIBRARY})
  get_filename_component(SMARTREDIS_LIBRARY_DIR ${SMARTREDIS_LIBRARY} DIRECTORY)

  include_directories(${SMARTREDIS_INCLUDE_DIR})

  message(STATUS "SmartRedis include directory: ${SMARTREDIS_INCLUDE_DIR}")
  message(STATUS "SmartRedis library directory: ${SMARTREDIS_LIBRARY_DIR}")
endif()

