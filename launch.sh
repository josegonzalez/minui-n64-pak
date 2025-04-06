#!/bin/sh
PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"
set -x

rm -f "$LOGS_PATH/$PAK_NAME.txt"
exec >>"$LOGS_PATH/$PAK_NAME.txt"
exec 2>&1

echo "$0" "$@"
cd "$PAK_DIR" || exit 1
mkdir -p "$USERDATA_PATH/$PAK_NAME"

architecture=arm
if uname -m | grep -q '64'; then
	architecture=arm64
fi

export EMU_DIR="$SDCARD_PATH/Emus/$PLATFORM/N64.pak/mupen64plus"
export PAK_DIR="$SDCARD_PATH/Emus/$PLATFORM/N64.pak"
export HOME="$USERDATA_PATH/N64-mupen64plus"
export LD_LIBRARY_PATH="$EMU_DIR/lib:$LD_LIBRARY_PATH"
export PATH="$EMU_DIR:$PAK_DIR/bin/$architecture:$PAK_DIR/bin/$PLATFORM:$PAK_DIR/bin:$PATH"
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

	if [ "$dpad_mode" = "f2" ]; then
		dpad_mode="joystick-on-f2"
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

write_settings_json() {
	# name: Controller Layout
	controller_layout="$(get_controller_layout)"
	# name: CPU Mode
	cpu_mode="$(get_cpu_mode)"
	# name: DPAD Mode
	dpad_mode="$(get_dpad_mode)"
	# name: Glide Aspect
	glide_aspect="$(get_glide_aspect)"
	# name: Mupen64Plus Version
	mupen64plus_version="$(get_mupen64plus_version)"
	# name: Video Plugin
	video_plugin="$(get_video_plugin)"

	jq -rM '{settings: .settings}' "$PAK_DIR/config.json" >"$GAMESETTINGS_DIR/settings.json"

	update_setting_key "$GAMESETTINGS_DIR/settings.json" "Controller Layout" "$controller_layout"
	update_setting_key "$GAMESETTINGS_DIR/settings.json" "CPU Mode" "$cpu_mode"
	update_setting_key "$GAMESETTINGS_DIR/settings.json" "DPAD Mode" "$dpad_mode"
	update_setting_key "$GAMESETTINGS_DIR/settings.json" "Glide Aspect Ratio" "$glide_aspect"
	update_setting_key "$GAMESETTINGS_DIR/settings.json" "Mupen64Plus Version" "$mupen64plus_version"
	update_setting_key "$GAMESETTINGS_DIR/settings.json" "Video Plugin" "$video_plugin"
	sync
}

# the settings.json file contains a "settings" array
# we have a series of settings that we need to update based on the values above
# for each setting, we need to find the index of the setting where the setting's name key matches the name above
# then we need to find the index of the option in the setting's options array that matches the value above
# and finally we need to update the setting's selected key to the index of the option
# the final settings.json should have a "settings" array, where each of the settings has an updated selected key
update_setting_key() {
	settings_file="$1"
	setting_name="$2"
	option_value="$3"

	# fetch the option index
	jq --arg name "$setting_name" --arg option "$option_value" '
 		.settings |= map(if .name == $name then . + {"selected": ((.options // []) | index($option) // -1)} else . end)
	' "$settings_file" >"$settings_file.tmp"
	mv -f "$settings_file.tmp" "$settings_file"
}

settings_menu() {
	mkdir -p "$GAMESETTINGS_DIR"

	rm -f "$GAMESETTINGS_DIR/controller-layout.tmp"
	rm -f "$GAMESETTINGS_DIR/cpu-mode.tmp"
	rm -f "$GAMESETTINGS_DIR/dpad-mode.tmp"
	rm -f "$GAMESETTINGS_DIR/mupen64plus-version.tmp"

	controller_layout="$(get_controller_layout)"
	cpu_mode="$(get_cpu_mode)"
	dpad_mode="$(get_dpad_mode)"
	mupen64plus_version="$(get_mupen64plus_version)"

	write_settings_json

	r2_value="$(coreutils timeout .1s evtest /dev/input/event3 2>/dev/null | awk '/ABS_RZ/{getline; print}' | awk '{print $2}' || true)"
	if [ "$r2_value" = "255" ]; then
		while true; do

			minui_list_output="$(minui-list --file "$GAMESETTINGS_DIR/settings.json" --item-key "settings" --title "N64 Settings" --action-button "X" --action-text "PLAY" --write-value state --confirm-text "CONFIRM")" || {
				exit_code="$?"
				# 4 = action button
				# we break out of the loop because the action button is the play button
				if [ "$exit_code" -eq 4 ]; then
					# shellcheck disable=SC2016
					echo "$minui_list_output" | jq -r --arg name "Controller Layout" '.settings[] | select(.name == $name) | .options[.selected]' >"$GAMESETTINGS_DIR/controller-layout.tmp"
					# shellcheck disable=SC2016
					echo "$minui_list_output" | jq -r --arg name "CPU Mode" '.settings[] | select(.name == $name) | .options[.selected]' >"$GAMESETTINGS_DIR/cpu-mode.tmp"
					# shellcheck disable=SC2016
					echo "$minui_list_output" | jq -r --arg name "DPAD Mode" '.settings[] | select(.name == $name) | .options[.selected]' >"$GAMESETTINGS_DIR/dpad-mode.tmp"
					# shellcheck disable=SC2016
					echo "$minui_list_output" | jq -r --arg name "Mupen64Plus Version" '.settings[] | select(.name == $name) | .options[.selected]' >"$GAMESETTINGS_DIR/mupen64plus-version.tmp"

					break
				fi

				# 2 = back button, 3 = menu button
				# both are errors, so we exit with the exit code
				if [ "$exit_code" -ne 0 ]; then
					exit "$exit_code"
				fi
			}

			# fetch values for next loop
			controller_layout="$(echo "$minui_list_output" | jq -r --arg name "Controller Layout" '.settings[] | select(.name == $name) | .options[.selected]')"
			cpu_mode="$(echo "$minui_list_output" | jq -r --arg name "CPU Mode" '.settings[] | select(.name == $name) | .options[.selected]')"
			dpad_mode="$(echo "$minui_list_output" | jq -r --arg name "DPAD Mode" '.settings[] | select(.name == $name) | .options[.selected]')"
			mupen64plus_version="$(echo "$minui_list_output" | jq -r --arg name "Mupen64Plus Version" '.settings[] | select(.name == $name) | .options[.selected]')"

			# save values to disk
			echo "$minui_list_output" >"$GAMESETTINGS_DIR/settings.json"
			echo "$controller_layout" >"$GAMESETTINGS_DIR/controller-layout"
			echo "$cpu_mode" >"$GAMESETTINGS_DIR/cpu-mode"
			echo "$dpad_mode" >"$GAMESETTINGS_DIR/dpad-mode"
			echo "$mupen64plus_version" >"$GAMESETTINGS_DIR/mupen64plus-version"
			sync
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
		existing_governor="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
		existing_max_freq="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"
		echo performance >/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
		echo 1800000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
		ROM_PATH="$TEMP_ROM"

		7zzs e "$*" -so >"$TEMP_ROM"
		echo "$existing_governor" >/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
		echo "$existing_max_freq" >/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
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

	cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor >"$HOME/cpu_governor.txt"
	cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq >"$HOME/cpu_min_freq.txt"
	cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq >"$HOME/cpu_max_freq.txt"

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
	# auto-resume slot
	if [ -f "$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.st9" ]; then
		mv -f "$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.st9" "$SHARED_USERDATA_PATH/N64-mupen64plus/"
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

	killall minui-presenter >/dev/null 2>&1 || true
	echo "$message" 1>&2
	if [ "$seconds" = "forever" ]; then
		minui-presenter --message "$message" --timeout -1 &
	else
		minui-presenter --message "$message" --timeout "$seconds"
	fi
}

cleanup() {
	GOODNAME=""
	if [ -f "$LOGS_PATH/N64-mupen64plus.txt" ]; then
		GOODNAME="$(grep 'Core: Goodname:' "$LOGS_PATH/N64-mupen64plus.txt" | cut -d: -f3- | xargs || true)"
		OVERRIDE_GOODNAME="$(grep 'Core: Name:' "$LOGS_PATH/N64-mupen64plus.txt" | cut -d: -f3- | xargs || true)"
		if [ -n "$OVERRIDE_GOODNAME" ]; then
			GOODNAME="$OVERRIDE_GOODNAME"
		fi

		rm -f "$LOGS_PATH/N64-mupen64plus.txt"
	elif [ -f "$GAMESETTINGS_DIR/goodname" ]; then
		GOODNAME="$(cat "$GAMESETTINGS_DIR/goodname")"
	fi

	rm -f "/tmp/minui-list"
	rm -f "/tmp/mupen64plus.pid"
	rm -f "/tmp/stay_awake"
	rm -f "/tmp/force-power-off" "/tmp/force-power-off-tracker"
	killall emit-key >/dev/null 2>&1 || true
	killall evtest >/dev/null 2>&1 || true
	killall minui-presenter >/dev/null 2>&1 || true

	if [ -f "$HOME/cpu_governor.txt" ]; then
		governor="$(cat "$HOME/cpu_governor.txt")"
		echo "$governor" >/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
		rm -f "$HOME/cpu_governor.txt"
	fi
	if [ -f "$HOME/cpu_min_freq.txt" ]; then
		min_freq="$(cat "$HOME/cpu_min_freq.txt")"
		echo "$min_freq" >/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq
		rm -f "$HOME/cpu_min_freq.txt"
	fi
	if [ -f "$HOME/cpu_max_freq.txt" ]; then
		max_freq="$(cat "$HOME/cpu_max_freq.txt")"
		echo "$max_freq" >/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
		rm -f "$HOME/cpu_max_freq.txt"
	fi

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
	# auto-resume slot
	if [ -f "$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.st9" ]; then
		mv -f "$XDG_DATA_HOME/mupen64plus/save/$sanitized_rom_name.st9" "$SHARED_USERDATA_PATH/N64-mupen64plus/"
	fi

	if [ -f "$TEMP_ROM" ]; then
		rm -f "$TEMP_ROM"
	fi

	if [ -f "/tmp/gptokeyb2.pid" ]; then
		kill -9 "$(cat "/tmp/gptokeyb2.pid")"
		rm -f "/tmp/gptokeyb2.pid"
	fi
}

launch_mupen64plus() {
	ROM_PATH="$1"
	SAVESTATE_PATH="$2"

	if [ -f "$SAVESTATE_PATH" ]; then
		"$mupen64plus_bin" --datadir "$XDG_DATA_HOME" --configdir "$XDG_CONFIG_HOME" --nosaveoptions --plugindir "$PLUGIN_DIR" --resolution "$resolution" --sshotdir "$SCREENSHOT_DIR" --savestate "$SAVESTATE_PATH" "$ROM_PATH" | coreutils tee "$LOGS_PATH/N64-mupen64plus.txt"
	else
		"$mupen64plus_bin" --datadir "$XDG_DATA_HOME" --configdir "$XDG_CONFIG_HOME" --nosaveoptions --plugindir "$PLUGIN_DIR" --resolution "$resolution" --sshotdir "$SCREENSHOT_DIR" "$ROM_PATH" | coreutils tee "$LOGS_PATH/N64-mupen64plus.txt"
	fi
}

main() {
	echo "1" >/tmp/stay_awake
	trap "cleanup" EXIT INT TERM HUP QUIT

	if [ "$PLATFORM" = "tg3040" ] && [ -z "$DEVICE" ]; then
		export DEVICE="brick"
		export PLATFORM="tg5040"
	fi

	if [ "$PLATFORM" != "tg5040" ]; then
		show_message "$PLATFORM is not a supported platform" 2
		exit 1
	fi

	if [ ! -f "$1" ]; then
		show_message "ROM not found" 2
		exit 1
	fi

	TEMP_ROM=$(mktemp)
	ROM_PATH="$(TEMP_ROM="$TEMP_ROM" get_rom_path "$*")"
	if [ -z "$ROM_PATH" ]; then
		return
	fi

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

	launch_mupen64plus "$ROM_PATH" "$SAVESTATE_PATH" &
	sleep 0.5

	emit-key -k p -s &
	PAUSE_EMIT_KEY_PID="$!"

	pgrep -f "$mupen64plus_bin" | tail -n 1 >"/tmp/mupen64plus.pid"
	PROCESS_PID="$(cat "/tmp/mupen64plus.pid")"
	if [ -f "$PAK_DIR/bin/$PLATFORM/handle-power-button" ]; then
		chmod +x "$PAK_DIR/bin/$PLATFORM/handle-power-button"
		PAUSE_EMIT_KEY_PID="$PAUSE_EMIT_KEY_PID" handle-power-button "$PROCESS_PID" "$ROM_PATH" &
	fi

	while kill -0 "$PROCESS_PID" 2>/dev/null; do
		sleep 1
	done

	if [ -f "/tmp/force-power-off" ]; then
		AUTO_RESUME_FILE="$SHARED_USERDATA_PATH/.minui/auto_resume.txt"
		echo "$ROM_PATH" >"$AUTO_RESUME_FILE"
		sync
		rm /tmp/minui_exec
		poweroff
		while :; do
			sleep 1
		done
	fi
}

main "$@"
