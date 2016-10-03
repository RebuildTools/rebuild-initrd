#!/bin/bash
#
# Rebuild Agent - Build Script
# ============================
#
# This rebuild script is a simple
# way of building the Rebuild Agent
# without having to manually run every
# command required to produce the final
# ramdisk
#
# Author: Liam Haworth <liam@haworth.id.au>
#

#####
## Load dependencies and define global variables
#####
. initrd_src/lib/rebuild/functions

pushd `dirname $0` > /dev/null
SCRIPTPATH=`pwd`
popd > /dev/null

[ -z "${INITRD_SRC}" ] && INITRD_SRC=$SCRIPTPATH/initrd_src
[ -z "${INITRD_DST}" ] && INITRD_DST=$SCRIPTPATH/output

#####
## Script Helper Functions
#####

#// Checks if the provided name
#// is a delcared function in this
#// script.
#//
#// PARAMS:
#//   $1 - The name of the function
#//
#// RETURNS: Boolean - Returns true if the function is declared
isAFunction() {
	type $1 2>&1 | grep "is a function" 1>/dev/null 2>&1
}

#// Checks if the provided name
#// is an executable binary in
#// the systems path.
#//
#// PARAMS:
#//   $1 - The name of the binary
#//
#// RETURNS:  Boolean - Returns true if the binary exists
binaryExists() {
	if hash $1 2>/dev/null; then
		return 0
	else
		return 1
	fi
}

#####
## Script Tasks
#####

#// Packages the intird source into
#// gzip compressed CPIO archive that
#// can be unpacked and executed by the
#// Linux Kernel
package() {
	logInfo "Packaging the final ram disk image"

	logDebug "Checking for [cpio] binary"
	binaryExists "cpio" || logFatal "The [cpio] binary doesn't exist, please install it!"

	logDebug "Checking for [gzip] binary"
	binaryExists "gzip" || logFatal "The [gzip] binary doesn't exist, please install it!"

	logDebug "Checking for source files directory: ${INITRD_SRC}"
	if [ ! -d $INITRD_SRC ]; then logFatal "The provided source directory [${INITRD_SRC}] doesn't exist!"
	else logDebug "Changing directories into the source directory" && cd $INITRD_SRC; fi

	logDebug "Checking for destination directory: ${INITRD_DST}"
	[ ! -d $INITRD_DST ] && logWarn "The output directory [${INITRD_DST}] doesn't exist, making it" && mkdir -p $INITRD_DST

	logDebug "Build CPIO package and compressing to output file"
	find . ! -name '.gitkeep' | cpio -o -H newc 2>/dev/null | gzip > $INITRD_DST/initrd.gz

	logDebug "Changing back to the previous directory"
	cd - >/dev/null

	logInfo "Finished packaging the ram disk, final output file: ${INITRD_DST}/initrd.gz"
}

#####
## Script Help Message
#####

#// Shows the helps message
#// for this build script
#//
#// RETURNS: String - The help message for this script
showHelp() {
	echo -e "Usage: $0 [TASK ..]\n"

	echo "Rebuild Agent - Build Script"
	echo -e "============================\n"
	echo "This script provide tasks to help with"
	echo -e "compiling of the Rebuild Agent ram disk.\n\n"

	echo "Environment Variables:"
	printf "\t%-20s - %s\n" "LOGLEVEL" "Sets the logging level of the build script (Default: 4 | 1 - PANIC, 2 - FATAL, 3 - WARN, 4 - INFO, 5 - DEBUG)"
	printf "\t%-20s - %s\n" "INITRD_SRC" "Defines the location of the ram disk source files (Default: ${SCRIPTPATH}/initrd_src)"
	printf "\t%-20s - %s\n" "INITRD_DST" "Defines the output location of the packaged initrd file (Default: ${SCRIPTPATH}/output)"

	echo -e "\n"

	echo "Tasks:"
	printf "\t%-20s - %s\n" "showHelp" "Shows this help message"
	printf "\t%-20s - %s\n" "package" "Packages the ram disk source (initrd_src) into the final ram disk image"

	echo -e "\n\n"
}

#####
## Script Entry Point
#####

logDebug "Detecting my full path as: ${SCRIPTPATH}"

if [ $# == 0 ]; then
	showHelp
else
	logDebug "Checking if all tasks exist before executing"
	for task in $@; do
		logDebug "Checking for task [${task}]"
		if ! isAFunction "${task}"; then
			showHelp
			logFatal "No such task: ${task}"
		fi
	done

	logDebug "All tasks selected exist, running them!"
	logInfo "Starting Rebuild Agent Build Script"

	for task in $@; do
		logDebug "Running task [${task}]"
		$task
	done

	logInfo "All tasks completed successfully!"
fi
