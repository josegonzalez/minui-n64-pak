#!/bin/sh
set -eo pipefail
[ -f "$USERDATA_PATH/N64-mupen64plus/debug" ] && set -x
echo $0 $*

rm -f "$LOGS_PATH/N64.txt"
exec >>"$LOGS_PATH/N64.txt"
exec 2>&1

echo "1" >/tmp/stay_awake

export EMU_DIR="$SDCARD_PATH/Emus/$PLATFORM/N64.pak/mupen64plus"
export PACK_DIR="$SDCARD_PATH/Emus/$PLATFORM/N64.pak"
export HOME="$USERDATA_PATH/N64-mupen64plus"
export LD_LIBRARY_PATH="$EMU_DIR/lib:$LD_LIBRARY_PATH"
export PATH="$EMU_DIR:$PACK_DIR/bin:$PATH"
export XDG_CONFIG_HOME="$USERDATA_PATH/N64-mupen64plus/config"
export XDG_DATA_HOME="$USERDATA_PATH/N64-mupen64plus/data"

export ROM_NAME="$(basename -- "$*")"
export GAMESETTINGS_DIR="$USERDATA_PATH/N64-mupen64plus/game-settings/$ROM_NAME"
export SCREENSHOT_DIR="$SDCARD_PATH/Screenshots"

get_rom_name() {
	ROM_NAME="$1"
	SANITIZED_ROM_NAME="${ROM_NAME%.*}"
	if [ -f "$GAMESETTINGS_DIR/goodname" ]; then
		SANITIZED_ROM_NAME="$(cat "$GAMESETTINGS_DIR/goodname")"
	fi

	echo "$SANITIZED_ROM_NAME"
}

get_controller_layout() {
	controller_layout="default"
	if [ -f "$GAMESETTINGS_DIR/controller-layout" ]; then
		controller_layout="$(cat "$GAMESETTINGS_DIR/controller-layout")"
	fi
	if [ -f "$GAMESETTINGS_DIR/controller-layout.tmp" ]; then
		controller_layout="$(cat "$GAMESETTINGS_DIR/controller-layout.tmp")"
	fi
	echo "$controller_layout"
}

get_cpu_mode() {
	cpu_mode="ondemand"
	if [ -f "$GAMESETTINGS_DIR/cpu-mode" ]; then
		cpu_mode="$(cat "$GAMESETTINGS_DIR/cpu-mode")"
	fi
	if [ -f "$GAMESETTINGS_DIR/cpu-mode.tmp" ]; then
		cpu_mode="$(cat "$GAMESETTINGS_DIR/cpu-mode.tmp")"
	fi
	echo "$cpu_mode"
}

get_dpad_mode() {
	dpad_mode="dpad"
	if [ -f "$GAMESETTINGS_DIR/dpad-mode" ]; then
		dpad_mode="$(cat "$GAMESETTINGS_DIR/dpad-mode")"
	fi
	if [ -f "$GAMESETTINGS_DIR/dpad-mode.tmp" ]; then
		dpad_mode="$(cat "$GAMESETTINGS_DIR/dpad-mode.tmp")"
	fi
	echo "$dpad_mode"
}

get_glide_aspect() {
	glide_aspect="4:3"
	if [ -f "$GAMESETTINGS_DIR/glide-aspect" ]; then
		glide_aspect="$(cat "$GAMESETTINGS_DIR/glide-aspect")"
	fi
	if [ -f "$GAMESETTINGS_DIR/glide-aspect.tmp" ]; then
		glide_aspect="$(cat "$GAMESETTINGS_DIR/glide-aspect.tmp")"
	fi
	echo "$glide_aspect"
}

get_mupen64plus_version() {
	mupen64plus_version="2.6.0"
	if [ -f "$GAMESETTINGS_DIR/mupen64plus-version" ]; then
		mupen64plus_version="$(cat "$GAMESETTINGS_DIR/mupen64plus-version")"
	fi
	if [ -f "$GAMESETTINGS_DIR/mupen64plus-version.tmp" ]; then
		mupen64plus_version="$(cat "$GAMESETTINGS_DIR/mupen64plus-version.tmp")"
	fi
	echo "$mupen64plus_version"
}

get_video_plugin() {
	video_plugin="rice"
	if [ -f "$GAMESETTINGS_DIR/video-plugin" ]; then
		video_plugin="$(cat "$GAMESETTINGS_DIR/video-plugin")"
	fi
	if [ -f "$GAMESETTINGS_DIR/video-plugin.tmp" ]; then
		video_plugin="$(cat "$GAMESETTINGS_DIR/video-plugin.tmp")"
	fi
	echo "$video_plugin"
}

settings_menu() {
	mkdir -p "$GAMESETTINGS_DIR"

	rm -f "$GAMESETTINGS_DIR/dpad-mode.tmp"
	rm -f "$GAMESETTINGS_DIR/glide-aspect.tmp"
	rm -f "$GAMESETTINGS_DIR/video-plugin.tmp"

	controller_layout="$(get_controller_layout)"
	cpu_mode="$(get_cpu_mode)"
	dpad_mode="$(get_dpad_mode)"
	glide_aspect="$(get_glide_aspect)"
	mupen64plus_version="$(get_mupen64plus_version)"
	video_plugin="$(get_video_plugin)"

	r2_value="$(coreutils timeout .1s evtest /dev/input/event3 2>/dev/null | awk '/ABS_RZ/{getline; print}' | awk '{print $2}' || true)"
	if [ "$r2_value" = "255" ]; then
		while true; do
			minui_list_file="/tmp/minui-list"
			rm -f "$minui_list_file"
			touch "$minui_list_file"

			if [ "$controller_layout" = "default" ]; then
				echo "Controller Layout: Default" >>"$minui_list_file"
			else
				echo "Controller Layout: Lonko" >>"$minui_list_file"
			fi

			if [ "$cpu_mode" = "ondemand" ]; then
				echo "CPU Mode: On Demand" >>"$minui_list_file"
			else
				echo "CPU Mode: Performance" >>"$minui_list_file"
			fi

			if [ "$dpad_mode" = "dpad" ]; then
				echo "DPAD Mode: DPAD" >>"$minui_list_file"
			elif [ "$dpad_mode" = "joystick" ]; then
				echo "DPAD Mode: Joystick" >>"$minui_list_file"
			else
				echo "DPAD Mode: Joystick on F2" >>"$minui_list_file"
			fi

			if [ "$mupen64plus_version" = "2.6.0" ]; then
				echo "Mupen64Plus Version: 2.6.0" >>"$minui_list_file"
			else
				echo "Mupen64Plus Version: 2.5.9" >>"$minui_list_file"
			fi

			echo "Save settings for game" >>"$minui_list_file"
			echo "Start game" >>"$minui_list_file"

			selection="$("minui-list-$PLATFORM" --format text --file "$minui_list_file" --header "N64 Settings")"
			exit_code=$?
			# exit codes: 2 = back button, 3 = menu button
			if [ "$exit_code" -ne 0 ]; then
				break
			fi

			if echo "$selection" | grep -q "^Controller Layout: Default$"; then
				controller_layout="lonko"
			elif echo "$selection" | grep -q "^Controller Layout: Lonko$"; then
				controller_layout="default"
			elif echo "$selection" | grep -q "^CPU Mode: On Demand$"; then
				cpu_mode="performance"
			elif echo "$selection" | grep -q "^CPU Mode: Performance$"; then
				cpu_mode="ondemand"
			elif echo "$selection" | grep -q "^Video Plugin: Rice$"; then
				video_plugin="glide64mk2"
			elif echo "$selection" | grep -q "^Video Plugin: Glide$"; then
				video_plugin="rice"
			elif echo "$selection" | grep -q "^Glide aspect ratio: 4:3$"; then
				glide_aspect="16:9"
			elif echo "$selection" | grep -q "^Glide aspect ratio: 16:9$"; then
				glide_aspect="4:3"
			elif echo "$selection" | grep -q "^DPAD Mode: DPAD$"; then
				dpad_mode="joystick"
			elif echo "$selection" | grep -q "^DPAD Mode: Joystick$"; then
				dpad_mode="f2"
			elif echo "$selection" | grep -q "^DPAD Mode: Joystick on F2$"; then
				dpad_mode="dpad"
			elif echo "$selection" | grep -q "^Mupen64Plus Version: 2.5.9$"; then
				mupen64plus_version="2.6.0"
			elif echo "$selection" | grep -q "^Mupen64Plus Version: 2.6.0$"; then
				mupen64plus_version="2.5.9"
			elif echo "$selection" | grep -q "^Save settings for game$"; then
				echo "$controller_layout" >"$GAMESETTINGS_DIR/controller-layout"
				echo "$cpu_mode" >"$GAMESETTINGS_DIR/cpu-mode"
				echo "$dpad_mode" >"$GAMESETTINGS_DIR/dpad-mode"
				echo "$glide_aspect" >"$GAMESETTINGS_DIR/glide-aspect"
				echo "$mupen64plus_version" >"$GAMESETTINGS_DIR/mupen64plus-version"
				echo "$video_plugin" >"$GAMESETTINGS_DIR/video-plugin"
			elif echo "$selection" | grep -q "^Start game$"; then
				echo "$controller_layout" >"$GAMESETTINGS_DIR/controller-layout.tmp"
				echo "$cpu_mode" >"$GAMESETTINGS_DIR/cpu-mode.tmp"
				echo "$dpad_mode" >"$GAMESETTINGS_DIR/dpad-mode.tmp"
				echo "$glide_aspect" >"$GAMESETTINGS_DIR/glide-aspect.tmp"
				echo "$mupen64plus_version" >"$GAMESETTINGS_DIR/mupen64plus-version.tmp"
				echo "$video_plugin" >"$GAMESETTINGS_DIR/video-plugin.tmp"
				break
			fi
		done
	fi
}

get_rom_path() {
	if [ -z "$TEMP_ROM" ]; then
		return
	fi

	ROM_PATH=""
	case "$*" in
		*.n64 | *.v64 | *.z64)
			ROM_PATH="$*"
			;;
		*.zip | *.7z)
			echo performance >/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
			echo 1800000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
			ROM_PATH="$TEMP_ROM"

			7zzs e "$*" -so >"$TEMP_ROM"
			;;
	esac

	echo "$ROM_PATH"
}

copy_libmupen64plus() {
	mupen64plus_version="$(get_mupen64plus_version)"
	mkdir -p /usr/local/lib
	cp -f "$EMU_DIR/lib/${mupen64plus_version}/libmupen64plus.so.2" /usr/local/lib/libmupen64plus.so.2
}

configure_platform() {
	controller_layout="$(get_controller_layout)"
	mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"

	cp -f "$EMU_DIR/config/$PLATFORM/modes/$controller_layout/mupen64plus.cfg" "$XDG_CONFIG_HOME/mupen64plus.cfg"
	cp -f "$EMU_DIR/config/$PLATFORM/modes/$controller_layout/InputAutoCfg.ini" "$XDG_DATA_HOME/InputAutoCfg.ini"
	cp -f "$EMU_DIR/config/$PLATFORM/font.ttf" "$XDG_DATA_HOME/font.ttf"
	cp -f "$EMU_DIR/config/$PLATFORM/Glide64mk2.ini" "$XDG_DATA_HOME/Glide64mk2.ini"
	cp -f "$EMU_DIR/config/$PLATFORM/mupen64plus.ini" "$XDG_DATA_HOME/mupen64plus.ini"
	cp -f "$EMU_DIR/config/$PLATFORM/RiceVideoLinux.ini" "$XDG_DATA_HOME/RiceVideoLinux.ini"
}

configure_game_settings() {
	video_plugin="$(get_video_plugin)"
	glide_aspect="$(get_glide_aspect)"

	if [ "$video_plugin" = "glide64mk2" ]; then
		mkdir -p "$HOME/.cache/mupen64plus/glidehq"
		set_ra_cfg.sh "$XDG_CONFIG_HOME/mupen64plus.cfg" "VideoPlugin" "mupen64plus-video-glide64mk2.so"
		set_ra_cfg.sh "$XDG_CONFIG_HOME/mupen64plus.cfg" "aspect" "0"
		if [ "$glide_aspect" = "16:9" ]; then
			set_ra_cfg.sh "$XDG_CONFIG_HOME/mupen64plus.cfg" "aspect" "1"
		fi
	else
		set_ra_cfg.sh "$XDG_CONFIG_HOME/mupen64plus.cfg" "VideoPlugin" "mupen64plus-video-rice.so"
	fi
}

configure_controls() {
	dpad_mode="$(get_dpad_mode)"

	if [ "$dpad_mode" = "f2" ]; then
		mkdir -p /tmp/trimui_inputd/
		touch /tmp/trimui_inputd/dpad2axis_hold_f2
	fi

	if [ "$dpad_mode" = "joystick" ]; then
		mkdir -p /tmp/trimui_inputd/
		touch /tmp/trimui_inputd/input_no_dpad
		touch /tmp/trimui_inputd/input_dpad_to_joystick
	fi

	# remap keys
	mupen64plus_version="$(get_mupen64plus_version)"
	controller_layout="$(get_controller_layout)"
	LD_LIBRARY_PATH="$EMU_DIR/lib/${mupen64plus_version}:$LD_LIBRARY_PATH" gptokeyb2 -c "$EMU_DIR/config/$PLATFORM/modes/$controller_layout/defkeys.gptk" &
	GPTOKEYB2_PID="$!"
	sleep 0.3

	echo "$GPTOKEYB2_PID" >"/tmp/gptokeyb2.pid"
}

configure_cpu() {
	cpu_mode="$(get_cpu_mode)"

	if [ "$cpu_mode" = "performance" ]; then
		echo performance >/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
		echo 1608000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq
		echo 1800000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
	else
		echo ondemand >/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
		echo 1200000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq
		echo 1800000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
	fi
}

restore_save_states_for_game() {
	mkdir -p "$XDG_DATA_HOME/mupen64plus/save" "$SDCARD_PATH/Saves/N64/"
	sanitized_rom_name="$(get_rom_name "$ROM_NAME")"

	# check and copy platform-specific eep, mpk and st0 files that already exist
	# this may happen if the game was saved on the device but we lost power before
	# we could restore them to the normal MinUI paths
	if [ -f "$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.eep" ]; then
		mv -f "$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.eep" "$SDCARD_PATH/Saves/N64/"
	fi
	if [ -f "$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.mpk" ]; then
		mv -f "$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.mpk" "$SDCARD_PATH/Saves/N64/"
	fi
	if [ -f "$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.st0" ]; then
		mv -f "$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.st0" "$SHARED_USERDATA_PATH/N64-mupen64plus/"
	fi

	# eep and mpk files are the in-game saves and should be restored from SDCARD_PATH/Saves/N64/
	if [ -f "$SDCARD_PATH/Saves/N64/$sanitized_rom_name.eep" ]; then
		cp -f "$SDCARD_PATH/Saves/N64/$sanitized_rom_name.eep" "$XDG_DATA_HOME/mupen64plus/save/"
	fi
	if [ -f "$SDCARD_PATH/Saves/N64/$sanitized_rom_name.mpk" ]; then
		cp -f "$SDCARD_PATH/Saves/N64/$sanitized_rom_name.mpk" "$XDG_DATA_HOME/mupen64plus/save/"
	fi

	# st0 files are the save states and should be restored from SHARED_USERDATA_PATH/N64-mupen64plus/
	if [ -f "$SHARED_USERDATA_PATH/N64-mupen64plus/$sanitized_rom_name.st0" ]; then
		cp -f "$SHARED_USERDATA_PATH/N64-mupen64plus/$sanitized_rom_name.st0" "$XDG_DATA_HOME/mupen64plus/save/"
	fi

	touch /tmp/n64-saves-restored
}

get_resolution() {
	if [ "$PLATFORM" = "tg5040" ]; then
		if [ "$DEVICE" = "brick" ]; then
			echo "1024x768"
		else
			echo "1280x720"
		fi
	fi
}

show_message() {
	message="$1"
	seconds="$2"

	if [ -z "$seconds" ]; then
		seconds="forever"
	fi

	killall sdl2imgshow >/dev/null 2>&1 || true
	echo "$message" 1>&2
	if [ "$seconds" = "forever" ]; then
		sdl2imgshow \
			-i "$PAK_DIR/res/background.png" \
			-f "$PAK_DIR/res/fonts/BPreplayBold.otf" \
			-s 27 \
			-c "220,220,220" \
			-q \
			-t "$message" >/dev/null 2>&1 &
	else
		sdl2imgshow \
			-i "$PAK_DIR/res/background.png" \
			-f "$PAK_DIR/res/fonts/BPreplayBold.otf" \
			-s 27 \
			-c "220,220,220" \
			-q \
			-t "$message" >/dev/null 2>&1
		sleep "$seconds"
	fi
}

cleanup() {
	GOODNAME=""
	if [ -f "$LOGS_PATH/N64-mupen64plus.txt" ]; then
		GOODNAME="$(grep 'Core: Goodname:' "$LOGS_PATH/N64-mupen64plus.txt" | cut -d: -f3- | xargs || true)"
		rm -f "$LOGS_PATH/N64-mupen64plus.txt"
	elif [ -f "$GAMESETTINGS_DIR/goodname" ]; then
		GOODNAME="$(cat "$GAMESETTINGS_DIR/goodname")"
	fi

	rm -f "/tmp/minui-list"

	rm -f /tmp/stay_awake
	killall sdl2imgshow >/dev/null 2>&1 || true

	# cleanup remap
	rm -f /tmp/trimui_inputd/input_no_dpad
	rm -f /tmp/trimui_inputd/input_dpad_to_joystick
	rm -f /tmp/trimui_inputd/dpad2axis_hold_f2

	# remove resume slot
	rm -f /tmp/resume_slot.txt

	if [ -n "$GOODNAME" ]; then
		echo "$GOODNAME" >"$GAMESETTINGS_DIR/goodname"
	fi

	sanitized_rom_name="$(get_rom_name "$ROM_NAME")"

	# do not touch the resume slot if the saves were not restored
	if [ -f "/tmp/n64-saves-restored" ]; then
		mkdir -p "$SHARED_USERDATA_PATH/.minui/N64"
		# create the resume slot if st0 exists
		if [ -f "$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.st0" ]; then
			echo "0" >"$SHARED_USERDATA_PATH/.minui/N64/$ROM_NAME.txt"
		else
			rm -f "$SHARED_USERDATA_PATH/.minui/N64/$ROM_NAME.txt"
		fi
	fi
	rm -f /tmp/n64-saves-restored

	mkdir -p "$SHARED_USERDATA_PATH/N64-mupen64plus"

	# restore saves to the normal MinUI paths
	if [ -f "$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.eep" ]; then
		mv -f "$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.eep" "$SDCARD_PATH/Saves/N64/"
	fi
	if [ -f "$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.mpk" ]; then
		mv -f "$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.mpk" "$SDCARD_PATH/Saves/N64/"
	fi
	if [ -f "$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.st0" ]; then
		mv -f "$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.st0" "$SHARED_USERDATA_PATH/N64-mupen64plus/"
	fi

	if [ -f "$TEMP_ROM" ]; then
		rm -f "$TEMP_ROM"
	fi

	if [ -f "/tmp/gptokeyb2.pid" ]; then
		kill -9 "$(cat "/tmp/gptokeyb2.pid")"
		rm -f "/tmp/gptokeyb2.pid"
	fi
}

main() {
	if [ "$PLATFORM" = "tg3040" ] && [ -z "$DEVICE" ]; then
		export DEVICE="brick"
		export PLATFORM="tg5040"
	fi

	if [ "$PLATFORM" != "tg5040" ]; then
		show_message "$PLATFORM is not a supported platform" 2
		exit 1
	fi

	TEMP_ROM=$(mktemp)
	ROM_PATH="$(TEMP_ROM="$TEMP_ROM" get_rom_path "$*")"
	if [ -z "$ROM_PATH" ]; then
		return
	fi

	trap cleanup INT TERM EXIT

	mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"

	settings_menu
	copy_libmupen64plus
	configure_platform
	configure_game_settings
	configure_controls
	configure_cpu
	restore_save_states_for_game

	# handle loading the save state if it exists
	sanitized_rom_name="$(get_rom_name "$ROM_NAME")"
	save_state=""
	if [ -f "/tmp/resume_slot.txt" ]; then
		save_state="$(xargs <"/tmp/resume_slot.txt")"
	fi
	SAVESTATE_PATH="$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.st${save_state}"

	resolution="$(get_resolution)"

	mupen64plus_version="$(get_mupen64plus_version)"
	mupen64plus_bin="mupen64plus-${mupen64plus_version}"
	PLUGIN_DIR="$EMU_DIR/plugin/$PLATFORM/${mupen64plus_version}"
	export LD_LIBRARY_PATH="$EMU_DIR/lib/${mupen64plus_version}:$LD_LIBRARY_PATH"

	mkdir -p "$SDCARD_PATH/Screenshots"
	rm -f "$LOGS_PATH/N64-mupen64plus.txt"
	if [ -f "$SAVESTATE_PATH" ]; then
		"$mupen64plus_bin" --datadir "$XDG_DATA_HOME" --configdir "$XDG_CONFIG_HOME" --nosaveoptions --plugindir "$PLUGIN_DIR" --resolution "$resolution" --sshotdir "$SCREENSHOT_DIR" --savestate "$SAVESTATE_PATH" "$ROM_PATH" | coreutils tee "$LOGS_PATH/N64-mupen64plus.txt" || true
	else
		"$mupen64plus_bin" --datadir "$XDG_DATA_HOME" --configdir "$XDG_CONFIG_HOME" --nosaveoptions --plugindir "$PLUGIN_DIR" --resolution "$resolution" --sshotdir "$SCREENSHOT_DIR" "$ROM_PATH" | coreutils tee "$LOGS_PATH/N64-mupen64plus.txt" || true
	fi
}

main "$@"
