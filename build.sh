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

## Global
[ -z "${OUTPUT_DIR}" ] && OUTPUT_DIRECTORY=$SCRIPTPATH/output


## Task: package
[ -z "${INITRD_SRC}" ] && INITRD_SRC=$SCRIPTPATH/initrd_src


## Task: buildKernel
KERNEL_SRC_GIT="https://github.com/torvalds/linux.git"
[ -z "${KERNEL_BUILD_CONFIG}" ] && KERNEL_BUILD_CONFIG=$SCRIPTPATH/linux-kernel.config
[ -z "${KERNEL_VERSION_TAG}" ] && KERNEL_VERSION_TAG="v4.8"
[ -z "${KERNEL_TMP_DIR}" ] && KERNEL_TMP_DIR=/tmp/rebuild_linux_kernel_src

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

#// Leverages #binaryExists to check
#// for a binary but adds debug logging
#// and error throwing (If the binary doesn't
#// exist).
#//
#// PARAMS:
#//   $1 - The name of the binary
checkForBinary() {
	logDebug "Checking for [${1}] binary"

	if binaryExists "${1}"; then
		return 0
	else
		logFatal "The binary [${1}] doesn't exist, please install it!"
	fi
}

#// Counts the number of CPU cores
#// available on the machine this
#// script is run on
getCpuCount() {
	 cat /proc/cpuinfo | awk '/^processor/{print $3}' | wc -l
}

#// Runs a shell command and captures
#// stderr & stdout, once the command 
#// finishes running it checks the exit
#// code to see if the command exited with
#// errors (and if those errors are allowed)
#//
#// PARAMS:
#//   $1 String - The info box message to show while running the command
#//   $2 String - The command to run
#//   $3 String - (Optional) A comma seperated list of acceptable non-zero exit codes
runCmd() {
	logDebug "${1}"
        local cmd_output=$($2 2>&1)
        local cmd_exitcode=$?

        if [ $cmd_exitcode -gt 0 ]; then
                local isGoodCode=false

                if [ ! -z "${3}" ]; then
                        for allowedCode in $(echo "${3}" | sed 's/,/ /g'); do
                                [ $allowedCode == $cmd_exitcode ] && isGoodCode=true
                        done
                fi

                if ! $isGoodCode; then
                        logPanic "Command exited with a non-zero code [$cmd_exitcode] when \"${1}\""
			logPanic "Command run: ${2}"
			logFatal "Command output:\n${cmd_output}"
                fi
        fi  
}

#####
## Script Tasks
#####

buildKernel() {
	logInfo "Building the Linux Kernel"

	checkForBinary "git"
	checkForBinary "make"
	
	[ -d $KERNEL_TMP_DIR ] && logWarn "Temporary build directory for kernel exists, clearing it" && rm -rf $KERNEL_TMP_DIR

	runCmd "Making temporary build directory for Linux Kernel" "mkdir ${KERNEL_TMP_DIR}"

	runCmd "Cloning Linux Kernel source" "git clone ${KERNEL_SRC_GIT} ${KERNEL_TMP_DIR}"

	logDebug "Copying kernel build config to source directory"
	\cp -f $KERNEL_BUILD_CONFIG $KERNEL_TMP_DIR/.config

	logDebug "Changing directory to source"
	cd $KERNEL_TMP_DIR

	runCmd "Checking out to the desired kernel version" "git checkout tags/${KERNEL_VERSION_TAG}"

	local buildCoreUse=$(($(getCpuCount)/2))
	runCmd "Compiling kernel with [${buildCoreUse}] CPUs" "make -j${buildCoreUse}"

	logDebug "Changing back to the previous directory"
	cd - >/dev/null

	logDebug "Checking for destination directory: ${OUTPUT_DIRECTORY}"
	[ ! -d $INITRD_DST ] && logWarn "The output directory [${OUTPUT_DIRECTORY}] doesn't exist, making it" && mkdir -p ${OUTPUT_DIRECTORY}

	logDebug "Copying compiled kernel to output directory"
	\cp -f $KERNEL_TMP_DIR/arch/x86/boot/bzImage $OUTPUT_DIRECTORY/linux-kernel

	logInfo "Finished build the Linux Kernel, final output file: ${OUTPUT_DIRECTORY}/linux-kernel"
}

#// Packages the intird source into
#// gzip compressed CPIO archive that
#// can be unpacked and executed by the
#// Linux Kernel
package() {
	logInfo "Packaging the final ram disk image"

	checkForBinary "cpio"
	checkForBinary "gzip"

	logDebug "Checking for source files directory: ${INITRD_SRC}"
	if [ ! -d $INITRD_SRC ]; then logFatal "The provided source directory [${INITRD_SRC}] doesn't exist!"
	else logDebug "Changing directories into the source directory" && cd $INITRD_SRC; fi

	logDebug "Checking for destination directory: ${OUTPUT_DIRECTORY}"
	[ ! -d $INITRD_DST ] && logWarn "The output directory [${OUTPUT_DIRECTORY}] doesn't exist, making it" && mkdir -p ${OUTPUT_DIRECTORY}

	logDebug "Build CPIO package and compressing to output file"
	find . ! -name '.gitkeep' | cpio -o -H newc 2>/dev/null | gzip > ${OUTPUT_DIRECTORY}/initrd.gz

	logDebug "Changing back to the previous directory"
	cd - >/dev/null

	logInfo "Finished packaging the ram disk, final output file: ${OUTPUT_DIRECTORY}/initrd.gz"
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

	echo -e "\t=== GLOBAL ==="	
	printf "\t%-20s - %s\n" "LOGLEVEL" "Sets the logging level of the build script (Default: 4 | 1 - PANIC, 2 - FATAL, 3 - WARN, 4 - INFO, 5 - DEBUG)"

	printf "\n\t=== TASK: %-10s ===\n" "buildKernel"
	printf "\t%-20s - %s\n" "KERNEL_BUILD_CONFIG" "Defines the path to the Linux Kernel build config (Default: ${SCRIPTPATH}/linux-kernel.config)"
	printf "\t%-20s - %s\n" "KERNEL_VERSION_TAG" "Defines the git tag of desired Linux Kernel version (Default: v4.8)"
	printf "\t%-20s - %s\n" "KERNEL_TPM_DIR" "Defines the temp directory used when compiling the kernel (Default: /tmp/rebuild_linux_kernel_src)"

	printf "\n\t=== TASK: %-10s ===\n" "package"
	printf "\t%-20s - %s\n" "INITRD_SRC" "Defines the location of the ram disk source files (Default: ${SCRIPTPATH}/initrd_src)"
	printf "\t%-20s - %s\n" "INITRD_DST" "Defines the output location of the packaged initrd file (Default: ${SCRIPTPATH}/output)"


	echo -e "\nTasks:"
	printf "\t%-20s - %s\n" "showHelp" "Shows this help message"
	printf "\t%-20s - %s\n" "buildKernel" "Downloads and compiles the Linux Kernel with the Rebuild Agent kernel configuration"
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
