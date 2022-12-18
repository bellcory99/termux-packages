termux_step_get_dependencies() {
	if [ "$TERMUX_SKIP_DEPCHECK" = true ] || [ "$TERMUX_PKG_METAPACKAGE" = true ]; then
		return 0
	fi

	if [ "$TERMUX_INSTALL_DEPS" = true ]; then
		# Download repo files
		termux_get_repo_files

		# When doing build on device, ensure that apt lists are up-to-date.
		if [ "$TERMUX_ON_DEVICE_BUILD" = "true" ]; then
			case "$TERMUX_APP_PACKAGE_MANAGER" in
				"apt") apt update;;
				"pacman") pacman -Sy;;
			esac
		fi
		while read PKG PKG_DIR; do
			if [ -z $PKG ]; then
				continue
			elif [ "$PKG" = "ERROR" ]; then
				termux_error_exit "Obtaining buildorder failed"
			fi
			# llvm doesn't build if ndk-sysroot is installed:
			if [ "$PKG" = "ndk-sysroot" ]; then continue; fi
			read DEP_ARCH DEP_VERSION DEP_VERSION_PAC <<< $(termux_extract_dep_info $PKG "${PKG_DIR}")
			if [ ! "$TERMUX_QUIET_BUILD" = true ]; then
				echo "Downloading dependency $PKG@$DEP_VERSION if necessary..."
			fi
			if [ -e "$TERMUX_BUILT_PACKAGES_DIRECTORY/$PKG" ]; then
				if [ "$(cat "$TERMUX_BUILT_PACKAGES_DIRECTORY/$PKG")" = "$DEP_VERSION" ]; then
					if [ ! "$TERMUX_QUIET_BUILD" = true ]; then
						echo "Skipping already built dependency $PKG@$DEP_VERSION"
					fi
					continue
				fi
			fi
			local force_build_dependency="$TERMUX_FORCE_BUILD_DEPENDENCIES"
			if [ "$TERMUX_FORCE_BUILD_DEPENDENCIES" = "true" ] && [ "$TERMUX_ON_DEVICE_BUILD" = "true" ] && termux_is_package_on_device_supported "$PKG_DIR"; then
				echo "Building dependency $PKG on device is not supported. It will be downloaded..."
				force_build_dependency="false"
			fi
			if [ "$force_build_dependency" = "true" ]; then
				[ ! "$TERMUX_QUIET_BUILD" = true ] && echo "Force building dependency $PKG instead of downloading due to -I flag..."
				termux_force_build_package_dependency -I
				continue
			else
				[ ! "$TERMUX_QUIET_BUILD" = true ] && echo "Downloading dependency $PKG@$DEP_VERSION if necessary..."

				if [ -e "$TERMUX_BUILT_PACKAGES_DIRECTORY/$PKG" ] && [ "$(cat "$TERMUX_BUILT_PACKAGES_DIRECTORY/$PKG")" = "$DEP_VERSION" ]; then
					[ ! "$TERMUX_QUIET_BUILD" = true ] && echo "Skipping already built dependency $PKG@$DEP_VERSION"
					continue
				fi
				if ! termux_download_deb_pac $PKG $DEP_ARCH $DEP_VERSION $DEP_VERSION_PAC; then
					echo "Download of $PKG@$DEP_VERSION from $TERMUX_REPO_URL failed, building instead"
					TERMUX_BUILD_IGNORE_LOCK=true ./build-package.sh -I --format $TERMUX_PACKAGE_FORMAT "${PKG_DIR}"
					termux_add_package_to_built_packages_list "$PKG"
					continue
				fi
				termux_add_package_to_built_packages_list "$PKG"
			fi
			if [ "$TERMUX_ON_DEVICE_BUILD" = "false" ]; then
				if [ ! "$TERMUX_QUIET_BUILD" = true ]; then
					echo "extracting $PKG to $TERMUX_COMMON_CACHEDIR-$DEP_ARCH..."
				fi
				(
					cd $TERMUX_COMMON_CACHEDIR-$DEP_ARCH
					ar x ${PKG}_${DEP_VERSION}_${DEP_ARCH}.deb data.tar.xz
					if tar -tf data.tar.xz|grep "^./$">/dev/null; then
						# Strip prefixed ./, to avoid possible
						# permission errors from tar
						tar -xf data.tar.xz --strip-components=1 \
							--no-overwrite-dir -C /
					else
						tar -xf data.tar.xz --no-overwrite-dir -C /
					fi
				)
			fi
			mkdir -p $TERMUX_BUILT_PACKAGES_DIRECTORY
			echo "$DEP_VERSION" > "$TERMUX_BUILT_PACKAGES_DIRECTORY/$PKG"
		done<<<$(./scripts/buildorder.py -i "$TERMUX_PKG_BUILDER_DIR" $TERMUX_PACKAGES_DIRECTORIES || echo "ERROR")
	else
		# Build dependencies
		while read PKG PKG_DIR; do
			if [ -z $PKG ]; then
				continue
			elif [ "$PKG" = "ERROR" ]; then
				termux_error_exit "Obtaining buildorder failed"
			fi
			# Built dependencies are put in the default TERMUX_OUTPUT_DIR instead of the specified one
			if [ "$TERMUX_FORCE_BUILD_DEPENDENCIES" = "true" ]; then
				[ ! "$TERMUX_QUIET_BUILD" = true ] && echo "Force building dependency $PKG..."
				if [ "$TERMUX_ON_DEVICE_BUILD" = "true" ] && termux_is_package_on_device_supported "$PKG_DIR"; then
					echo "Building $PKG on device is not supported. Consider passing -I flag to download it instead"
					return 1
				fi
				read DEP_ARCH DEP_VERSION DEP_VERSION_PAC <<< $(termux_extract_dep_info $PKG "${PKG_DIR}")
				termux_force_build_package_dependency -s
			else
				[ ! "$TERMUX_QUIET_BUILD" = true ] && echo "Building dependency $PKG if necessary..."
				TERMUX_BUILD_IGNORE_LOCK=true ./build-package.sh -s --format $TERMUX_PACKAGE_FORMAT "${PKG_DIR}"
				termux_add_package_to_built_packages_list "$PKG"
			fi
		done<<<$(./scripts/buildorder.py "$TERMUX_PKG_BUILDER_DIR" $TERMUX_PACKAGES_DIRECTORIES || echo "ERROR")
	fi
}



termux_force_build_package_dependency() {
	if [ "$TERMUX_BUILD_PACKAGE_CALL_DEPTH" -gt 0 ] && \
	   [[ " $TERMUX_BUILD_PACKAGE_CALL_BUILT_PACKAGES_LIST " == *" $PKG "* ]] && \
	   [ -e "$TERMUX_BUILT_PACKAGES_DIRECTORY/$PKG" ] && [ "$(cat "$TERMUX_BUILT_PACKAGES_DIRECTORY/$PKG")" = "$DEP_VERSION" ]; then
		[ ! "$TERMUX_QUIET_BUILD" = true ] && echo "Skipping already built dependency $PKG@$DEP_VERSION"
		continue
	fi

	TERMUX_BUILD_IGNORE_LOCK=true ./build-package.sh "$@" -F --format $TERMUX_PACKAGE_FORMAT "${PKG_DIR}"

	termux_add_package_to_built_packages_list "$PKG"
}

termux_is_package_on_device_supported() {
	local TERMUX_PKG_ON_DEVICE_BUILD_NOT_SUPPORTED="$(. ${1}/build.sh; echo $TERMUX_PKG_ON_DEVICE_BUILD_NOT_SUPPORTED)"
	[ "$TERMUX_PKG_ON_DEVICE_BUILD_NOT_SUPPORTED" = "true" ]
	return $?
}

termux_add_package_to_built_packages_list() {
	echo "$TERMUX_BUILD_PACKAGE_CALL_BUILT_PACKAGES_LIST"
	if [[ " $TERMUX_BUILD_PACKAGE_CALL_BUILT_PACKAGES_LIST " != *" $1 "* ]]; then
		TERMUX_BUILD_PACKAGE_CALL_BUILT_PACKAGES_LIST+=" $1"
	fi
}
