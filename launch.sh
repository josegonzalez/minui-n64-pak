#!/bin/sh
set -eo pipefail
set -x
echo $0 $*

rm "$LOGS_PATH/N64.txt"
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
export PLUGIN_DIR="$EMU_DIR/plugin/$PLATFORM"

settings_menu() {
	mkdir -p "$GAMESETTINGS_DIR"

	# get video plugin
	video_plugin="rice"
	if [ -f "$GAMESETTINGS_DIR/video-plugin" ]; then
		video_plugin="$(cat "$GAMESETTINGS_DIR/video-plugin")"
	fi

	# get the aspect ratio for glide
	glide_aspect="4:3"
	if [ -f "$GAMESETTINGS_DIR/glide-aspect" ]; then
		glide_aspect="$(cat "$GAMESETTINGS_DIR/glide-aspect")"
	fi

	dpad_mode="dpad"
	if [ -f "$GAMESETTINGS_DIR/dpad-mode" ]; then
		dpad_mode="$(cat "$GAMESETTINGS_DIR/dpad-mode")"
	fi

	l2_value="$(coreutils timeout .1s evtest /dev/input/event3 2>/dev/null | awk '/ABS_RZ/{getline; print}' | awk '{print $2}' || true)"
	if [ "$l2_value" = "255" ]; then
		while true; do
			minui_list_file="/tmp/minui-list"
			rm -f "$minui_list_file"
			touch "$minui_list_file"
			if [ "$video_plugin" = "rice" ]; then
				echo "Video Plugin: Rice" >>"$minui_list_file"
			else
				echo "Video Plugin: Glide" >>"$minui_list_file"
				if [ "$glide_aspect" = "4:3" ]; then
					echo "Glide aspect ratio: 4:3" >>"$minui_list_file"
				else
					echo "Glide aspect ratio: 16:9" >>"$minui_list_file"
				fi
			fi
			if [ "$dpad_mode" = "dpad" ]; then
				echo "DPAD Mode: DPAD" >>"$minui_list_file"
			elif [ "$dpad_mode" = "joystick" ]; then
				echo "DPAD Mode: Joystick" >>"$minui_list_file"
			else
				echo "DPAD Mode: Joystick on F2" >>"$minui_list_file"
			fi
			echo "Save settings for game" >>"$minui_list_file"
			echo "Start game" >>"$minui_list_file"

			selection="$("minui-list-$PLATFORM" --format text --file "$minui_list_file" --header "N64 Settings")"
			exit_code=$?
			# exit codes: 2 = back button, 3 = menu button
			if [ "$exit_code" -ne 0 ]; then
				break
			fi

			if echo "$selection" | grep -q "^Video Plugin: Rice$"; then
				video_plugin="glide"
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
			elif echo "$selection" | grep -q "^Save settings for game$"; then
				echo "$video_plugin" >"$GAMESETTINGS_DIR/video-plugin"
				echo "$glide_aspect" >"$GAMESETTINGS_DIR/glide-aspect"
				echo "$dpad_mode" >"$GAMESETTINGS_DIR/dpad-mode"
			elif echo "$selection" | grep -q "^Start game$"; then
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

		# get the 7zzs binary for the current architecture
		unzip7="$PACK_DIR/bin/7zzs-arm"
		if uname -m | grep -q '64'; then
			unzip7="$PACK_DIR/bin/7zzs-arm64"
		fi

		"$unzip7" e "$*" -so >"$TEMP_ROM"
		;;
	esac

	echo "$ROM_PATH"
}

copy_libmupen64plus() {
	if [ ! -f /usr/local/lib/libmupen64plus.so.2 ] && [ -f "$EMU_DIR/lib/libmupen64plus.so.2" ]; then
		mkdir -p /usr/local/lib
		cp "$EMU_DIR/lib/libmupen64plus.so.2" /usr/local/lib/libmupen64plus.so.2
	fi
}

configure_platform() {
	mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
	if [ ! -f "$XDG_CONFIG_HOME/mupen64plus.cfg" ]; then
		cp "$EMU_DIR/config/$PLATFORM/mupen64plus.cfg" "$XDG_CONFIG_HOME/mupen64plus.cfg"
	fi
	if [ ! -f "$XDG_DATA_HOME/font.ttf" ]; then
		cp "$EMU_DIR/config/$PLATFORM/font.ttf" "$XDG_DATA_HOME/font.ttf"
	fi
	if [ ! -f "$XDG_DATA_HOME/Glide64mk2.ini" ]; then
		cp "$EMU_DIR/config/$PLATFORM/Glide64mk2.ini" "$XDG_DATA_HOME/Glide64mk2.ini"
	fi
	if [ ! -f "$XDG_DATA_HOME/InputAutoCfg.ini" ]; then
		cp "$EMU_DIR/config/$PLATFORM/InputAutoCfg.ini" "$XDG_DATA_HOME/InputAutoCfg.ini"
	fi
	if [ ! -f "$XDG_DATA_HOME/mupen64plus.ini" ]; then
		cp "$EMU_DIR/config/$PLATFORM/mupen64plus.ini" "$XDG_DATA_HOME/mupen64plus.ini"
	fi
	if [ ! -f "$XDG_DATA_HOME/RiceVideoLinux.ini" ]; then
		cp "$EMU_DIR/config/$PLATFORM/RiceVideoLinux.ini" "$XDG_DATA_HOME/RiceVideoLinux.ini"
	fi
}

configure_game_settings() {
	video_plugin="rice"
	if [ -f "$GAMESETTINGS_DIR/video-plugin" ]; then
		video_plugin="$(cat "$GAMESETTINGS_DIR/video-plugin")"
	fi

	glide_aspect="4:3"
	if [ -f "$GAMESETTINGS_DIR/glide-aspect" ]; then
		glide_aspect="$(cat "$GAMESETTINGS_DIR/glide-aspect")"
	fi

	if [ "$video_plugin" = "glide64mk2" ]; then
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
	dpad_mode="dpad"
	if [ -f "$GAMESETTINGS_DIR/dpad-mode" ]; then
		dpad_mode="$(cat "$GAMESETTINGS_DIR/dpad-mode")"
	fi

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
	gptokeyb2 -c "$EMU_DIR/config/$PLATFORM/defkeys.gptk" &
	GPTOKEYB2_PID="$!"
	sleep 0.3

	echo "$GPTOKEYB2_PID" >"/tmp/gptokeyb2.pid"
}

configure_cpu() {
	echo ondemand >/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
	echo 1200000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq
	echo 1800000 >/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
}

copy_save_states_for_game() {
	mkdir -p "$XDG_DATA_HOME/mupen64plus/save" "$SDCARD_PATH/Saves/N64/"
	ROM_NO_EXTENSION="${ROM_NAME%.*}"

	# check and copy platform-specific eep, mpk and st0 files that already exist
	# this may happen if the game was saved on the device but we lost power before
	# we could restore them to the normal MinUI paths
	if [ -f "$XDG_DATA_HOME/mupen64plus/save/$ROM_NO_EXTENSION.eep" ]; then
		mv -f "$XDG_DATA_HOME/mupen64plus/save/$ROM_NO_EXTENSION.eep" "$SDCARD_PATH/Saves/N64/"
	fi
	if [ -f "$XDG_DATA_HOME/mupen64plus/save/$ROM_NO_EXTENSION.mpk" ]; then
		mv -f "$XDG_DATA_HOME/mupen64plus/save/$ROM_NO_EXTENSION.mpk" "$SDCARD_PATH/Saves/N64/"
	fi
	if [ -f "$XDG_DATA_HOME/mupen64plus/save/$ROM_NO_EXTENSION.st0" ]; then
		mv -f "$XDG_DATA_HOME/mupen64plus/save/$ROM_NO_EXTENSION.st0" "$SHARED_USERDATA_PATH/N64-mupen64plus/"
	fi

	# eep and mpk files are the in-game saves and should be restored from SDCARD_PATH/Saves/N64/
	if [ -f "$SDCARD_PATH/Saves/N64/$ROM_NO_EXTENSION.eep" ]; then
		cp -f "$SDCARD_PATH/Saves/N64/$ROM_NO_EXTENSION.eep" "$XDG_DATA_HOME/mupen64plus/save/"
	fi
	if [ -f "$SDCARD_PATH/Saves/N64/$ROM_NO_EXTENSION.mpk" ]; then
		cp -f "$SDCARD_PATH/Saves/N64/$ROM_NO_EXTENSION.mpk" "$XDG_DATA_HOME/mupen64plus/save/"
	fi

	# st0 files are the save states and should be restored from SHARED_USERDATA_PATH/N64-mupen64plus/
	if [ -f "$SHARED_USERDATA_PATH/N64-mupen64plus/$ROM_NO_EXTENSION.st0" ]; then
		cp -f "$SHARED_USERDATA_PATH/N64-mupen64plus/$ROM_NO_EXTENSION.st0" "$XDG_DATA_HOME/mupen64plus/save/"
	fi
}

cleanup() {
	rm -f "/tmp/minui-list"

	rm -f /tmp/stay_awake
	killall sdl2imgshow >/dev/null 2>&1 || true

	# cleanup remap
	rm -f /tmp/trimui_inputd/input_no_dpad
	rm -f /tmp/trimui_inputd/input_dpad_to_joystick
	rm -f /tmp/trimui_inputd/dpad2axis_hold_f2

	# remove resume slot
	rm -f /tmp/resume_slot.txt

	# copy the latest save if one was created
	mkdir -p "$SHARED_USERDATA_PATH/.minui/N64"
	if [ -f "$XDG_DATA_HOME/mupen64plus/save/$ROM_NO_EXTENSION.st0" ]; then
		echo "0" >"$SHARED_USERDATA_PATH/.minui/N64/$ROM_NAME.txt"
	else
		rm -f "$SHARED_USERDATA_PATH/.minui/N64/$ROM_NAME.txt"
	fi

	mkdir -p "$SHARED_USERDATA_PATH/N64-mupen64plus"

	ROM_NO_EXTENSION="${ROM_NAME%.*}"

	# restore saves to the normal MinUI paths
	if [ -f "$XDG_DATA_HOME/mupen64plus/save/$ROM_NO_EXTENSION.eep" ]; then
		mv -f "$XDG_DATA_HOME/mupen64plus/save/$ROM_NO_EXTENSION.eep" "$SDCARD_PATH/Saves/N64/"
	fi
	if [ -f "$XDG_DATA_HOME/mupen64plus/save/$ROM_NO_EXTENSION.mpk" ]; then
		mv -f "$XDG_DATA_HOME/mupen64plus/save/$ROM_NO_EXTENSION.mpk" "$SDCARD_PATH/Saves/N64/"
	fi
	if [ -f "$XDG_DATA_HOME/mupen64plus/save/$ROM_NO_EXTENSION.st0" ]; then
		mv -f "$XDG_DATA_HOME/mupen64plus/save/$ROM_NO_EXTENSION.st0" "$SHARED_USERDATA_PATH/N64-mupen64plus/"
	fi

	if [ -f "$TEMP_ROM" ]; then
		rm -f "$TEMP_ROM"
	fi

	if [ -f "/tmp/gptokeyb2.pid" ]; then
		kill -9 "$(cat "/tmp/gptokeyb2.pid")"
		rm -f "/tmp/gptokeyb2.pid"
	fi
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
	copy_save_states_for_game

	# handle loading the save state if it exists
	ROM_NO_EXTENSION="${ROM_NAME%.*}"
	save_state=""
	if [ -f "/tmp/resume_slot.txt" ]; then
		save_state="$(xargs <"/tmp/resume_slot.txt")"
	fi
	SAVESTATE_PATH="$XDG_DATA_HOME/mupen64plus/save/$ROM_NO_EXTENSION.st${save_state}"

	resolution="$(get_resolution)"

	mkdir -p "$SDCARD_PATH/Screenshots"
	if [ -f "$SAVESTATE_PATH" ]; then
		mupen64plus --datadir "$XDG_DATA_HOME" --configdir "$XDG_CONFIG_HOME" --nosaveoptions --plugindir "$PLUGIN_DIR" --resolution "$resolution" --sshotdir "$SCREENSHOT_DIR" --savestate "$SAVESTATE_PATH" "$ROM_PATH" || true
	else
		mupen64plus --datadir "$XDG_DATA_HOME" --configdir "$XDG_CONFIG_HOME" --nosaveoptions --plugindir "$PLUGIN_DIR" --resolution "$resolution" --sshotdir "$SCREENSHOT_DIR" "$ROM_PATH" || true
	fi
}

main "$@"
