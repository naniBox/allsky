#!/bin/bash

# Script to save a DAY or NIGHT image.
# It goes in ${ALLSKY_TMP} where the WebUI and local Allsky Website can find it.

ME="$( basename "${BASH_ARGV0}" )"

[[ ${ALLSKY_DEBUG_LEVEL} -ge 3 ]] && echo "${ME} $*"

#shellcheck source-path=.
source "${ALLSKY_HOME}/variables.sh" 		|| exit "${ALLSKY_ERROR_STOP}"
#shellcheck source-path=scripts
source "${ALLSKY_SCRIPTS}/functions.sh"		|| exit "${ALLSKY_ERROR_STOP}"

usage_and_exit()
{
	RET=${1}
	[[ ${RET} -ne 0 ]] && echo -ne "${RED}"
	echo -n "Usage: ${ME} DAY|NIGHT  full_path_to_image  [variable=value [...]]"
	[[ ${RET} -ne 0 ]] && echo -e "${NC}"
	exit "${RET}"
}
[[ $# -lt 2 ]] && usage_and_exit 1

# Export so other scripts can use it.
export DAY_OR_NIGHT="${1}"
[[ ${DAY_OR_NIGHT} != "DAY" && ${DAY_OR_NIGHT} != "NIGHT" ]] && usage_and_exit 1

# ${CURRENT_IMAGE} is the full path to a uniquely-named file created by the capture program.
# The file name is its final name in the ${ALLSKY_IMAGES}/<date> directory.
# Because it's a unique name we don't have to worry about another process overwritting it.
# We modify the file as needed and ultimately save a link to it as ${FULL_FILENAME} since
# that's what websites look for and what is uploaded.

# Export so other scripts can use it.
export CURRENT_IMAGE="${2}"
shift 2
if [[ ! -f ${CURRENT_IMAGE} ]] ; then
	echo -e "${RED}*** ${ME}: ERROR: File '${CURRENT_IMAGE}' not found; ignoring${NC}"
	exit 2
fi
if [[ ! -s ${CURRENT_IMAGE} ]] ; then
	echo -e "${RED}*** ${ME}: ERROR: File '${CURRENT_IMAGE}' is empty; ignoring${NC}"
	exit 2
fi

# Make sure only one save happens at once.
# Multiple concurrent saves (which can happen if the delay is short or post-processing
# is long) causes read and write errors.
PID_FILE="${ALLSKY_TMP}/saveImage-pid.txt"
ABORTED_MSG1="Another saveImage is in progress so the new one was aborted."
ABORTED_FIELDS="${CURRENT_IMAGE}"
ABORTED_MSG2="uploads"
# TODO: check delay settings and average times for module processing
# and tailor the message.
CAUSED_BY="This could be caused by very long module processing time or extremely short delays between images."
# Don't sleep too long or check too many times since processing an image should take at most
# a few seconds
if ! one_instance --pid-file "${PID_FILE}" --sleep "3s" --max-checks 3 \
		--aborted-count-file "${ALLSKY_ABORTEDSAVEIMAGE}" --aborted-fields "${ABORTED_FIELDS}" \
		--aborted-msg1 "${ABORTED_MSG1}" --aborted-msg2 "${ABORTED_MSG2}" \
		--caused-by "${CAUSED_BY}" ; then
	rm -f "${CURRENT_IMAGE}"
	exit 1
fi


# The image may be in a memory filesystem, so do all the processing there and
# leave the image used by the website(s) in that directory.
IMAGE_NAME=$( basename "${CURRENT_IMAGE}" )		# just the file name
WORKING_DIR=$( dirname "${CURRENT_IMAGE}" )		# the directory the image is currently in

# Optional full check for bad images.
HIGH="$( settings ".imageremovebadhigh" )"
LOW="$( settings ".imageremovebadlow" )"
# Make sure they are valid numbers.
[[ $( echo "${HIGH} == 0 || ${HIGH} > 100" | bc ) -eq 1 ]] && HIGH=0
[[ $( echo "${LOW} <= 0" | bc ) -eq 1 ]] && LOW=0

if [[ ${HIGH} != "0" || ${LOW} != "0" ]]; then
	# If the return code is 99, the file was bad and deleted so don't continue.
	AS_BAD_IMAGES_MEAN="$( "${ALLSKY_SCRIPTS}/removeBadImages.sh" "${WORKING_DIR}" "${IMAGE_NAME}" )"
	# removeBadImages.sh displayed error message and deleted the file.
	if [[ $? -eq 99 ]]; then
		exit 99
	elif [[ -n ${AS_BAD_IMAGES_MEAN} ]]; then
		export AS_BAD_IMAGES_MEAN
	fi
else
	AS_BAD_IMAGES_MEAN=""
fi

# If we didn't execute removeBadImages.sh do a quick sanity check on the image.
# OR, if we did execute removeBaImages.sh but we're cropping the image, get the image resolution.
CROP_TOP="$( settings ".imagecroptop" )"
CROP_RIGHT="$( settings ".imagecropright" )"
CROP_BOTTOM="$( settings ".imagecropbottom" )"
CROP_LEFT="$( settings ".imagecropleft" )"
CROP_IMAGE=$(( CROP_TOP + CROP_RIGHT + CROP_BOTTOM + CROP_LEFT ))	# will be > 0 if we're cropping
if [[ ${HIGH} != "0" || ${LOW} != "0" || ${CROP_IMAGE} -gt 0 ]]; then
	x=$(identify "${CURRENT_IMAGE}" 2>/dev/null)
	if [[ $? -ne 0 ]]; then
		echo -e "${RED}*** ${ME}: ERROR: '${CURRENT_IMAGE}' is corrupt; not saving.${NC}"
		exit 3
	fi

	if [[ ${CROP_IMAGE} -gt 0 ]]; then
		# Typical output:
			# image.jpg JPEG 4056x3040 4056x3040+0+0 8-bit sRGB 1.19257MiB 0.000u 0:00.000
		RESOLUTION=$(echo "${x}" | awk '{ print $3 }')
		# These are the resolution of the image (which may have been binned), not the sensor.
		RESOLUTION_X=${RESOLUTION%x*}	# everything before the "x"
		RESOLUTION_Y=${RESOLUTION##*x}	# everything after  the "x"
	fi
fi

# Get passed-in variables.
# Normally at least the exposure will be passed and the sensor temp if known.
while [[ $# -gt 0 ]]; do
	VARIABLE="AS_${1%=*}"		# everything before the "="
	VALUE="${1##*=}"			# everything after  the "="
	shift
	# Export the variable so other scripts we call can use it.
	# shellcheck disable=SC2086
	export ${VARIABLE}="${VALUE}"	# need "export" to get indirection to work
done
# Export other variables so user can use them in overlays
export AS_CAMERA_TYPE="$( settings ".cameratype" )"
export AS_CAMERA_MODEL="$( settings ".cameramodel" )"
if [[ -n ${AS_BAD_IMAGES_MEAN} ]]; then
	export AS_MEAN_NORMALIZED="$( echo "${AS_BAD_IMAGES_MEAN} * 255" | bc )"	# xxxx for testing
fi

# If ${AS_TEMPERATURE_C} is set, use it as the sensor temperature,
# otherwise use the temperature in ${TEMPERATURE_FILE}.
# TODO: Currently nothing creates the TEMPERATURE_FILE.  Eventually RPi cameras will.
if [[ -z ${AS_TEMPERATURE_C} ]]; then
	TEMPERATURE_FILE="${ALLSKY_TMP}/temperature.txt"
	if [[ -s ${TEMPERATURE_FILE} ]]; then	# -s so we don't use an empty file
		AS_TEMPERATURE_C=$( < "${TEMPERATURE_FILE}" )
	fi
fi

# If taking dark frames, save the dark frame then exit.
if [[ $(settings ".takedarkframes") == "true" ]]; then
	#shellcheck source-path=scripts
	source "${ALLSKY_SCRIPTS}/darkCapture.sh"
	exit 0
fi

# TODO: Dark subtract long-exposure images, even if during daytime.
# TODO: Need a config variable to specify the threshold to dark subtract.
# TODO: Possibly also for stretching below.
if [[ ${DAY_OR_NIGHT} == "NIGHT" ]]; then
	#shellcheck source-path=scripts
	source "${ALLSKY_SCRIPTS}/darkSubtract.sh"	# It will modify the image but not its name.
fi

# If any of the "convert"s below fail, exit since we won't know if the file was corrupted.

function display_error_and_exit()	# error message, notification string
{
	ERROR_MESSAGE="${1}"
	NOTIFICATION_STRING="${2}"
	echo -en "${RED}"
	echo -e "${ERROR_MESSAGE}" | while read -r MSG
		do
			[[ -n ${MSG} ]] && echo -e "    * ${MSG}"
		done
	echo -e "${NC}"
	# Create a custom error message.
	"${ALLSKY_SCRIPTS}/copy_notification_image.sh" --expires 15 "custom" \
		"red" "" "85" "" "" "" "10" "red" "${EXTENSION}" "" \
		"*** ERROR ***\nAllsky Stopped!\nInvalid ${NOTIFICATION_STRING} settings\nSee\n/var/log/allsky.log"

	# Don't let the service restart us because we will get the same error again.
	sudo systemctl stop allsky
	exit "${EXIT_ERROR_STOP}"
}

# Resize the image if required
RESIZE_W="$( settings ".imagresizewidth" )"
RESIZE_H="$( settings ".imagresizeheight" )"
if [[ ${RESIZE_W} -gt 0 && ${RESIZE_H} -gt 0 ]]; then
	IMG_RESIZE="true"
else
	IMG_RESIZE="false"
fi
if [[ ${IMG_RESIZE} == "true" ]] ; then
	# Make sure we were given numbers.
	ERROR_MSG=""
	if [[ ${RESIZE_W} != +([+0-9]) ]]; then		# no negative numbers allowed
		ERROR_MSG="${ERROR_MSG}\n'Image Resize Height' (${RESIZE_W}) must be a number."
	fi
	if [[ ${RESIZE_H} != +([+0-9]) ]]; then
		ERROR_MSG="${ERROR_MSG}\n'Image Resize Width' (${RESIZE_H}) must be a number."
	fi
	if [[ -n ${ERROR_MSG} ]]; then
		echo -e "${RED}*** ${ME}: ERROR: Image resize number(s) invalid.${NC}"
		display_error_and_exit "${ERROR_MSG}" "Image Resize"
	fi

	[[ ${ALLSKY_DEBUG_LEVEL} -ge 3 ]] && echo "*** ${ME}: Resizing '${CURRENT_IMAGE}' to ${RESIZE_W}x${RESIZE_H}"
	if ! convert "${CURRENT_IMAGE}" -resize "${RESIZE_W}x${RESIZE_H}" "${CURRENT_IMAGE}" ; then
		echo -e "${RED}*** ${ME}: ERROR: image resize failed; not saving${NC}"
		exit 4
	fi
fi

# Crop the image if required
if [[ ${CROP_IMAGE} -gt 0 ]]; then
	# If the image was just resized, the resolution changed, so reset the variables.
	if [[ ${IMG_RESIZE} == "true" ]]; then
		RESOLUTION_X=${RESIZE_W}
		RESOLUTION_Y=${RESIZE_H}
	fi

	# Perform basic checks on crop settings.
	ERROR_MSG="$( checkCropValues "${CROP_TOP}" "${CROP_RIGHT}" "${CROP_BOTTOM}" "${CROP_LEFT}" \
		"${RESOLUTION_X}" "${RESOLUTION_Y}" )"
	if [[ -z ${ERROR_MSG} ]]; then
		if [[ ${ALLSKY_DEBUG_LEVEL} -ge 3 ]]; then
			CROP_WIDTH=$(( RESOLUTION_X - CROP_RIGHT - CROP_LEFT ))
			CROP_HEIGHT=$(( RESOLUTION_Y - CROP_TOP - CROP_BOTTOM ))
			echo -e "*** ${ME} Cropping '${CURRENT_IMAGE}' to ${CROP_WIDTH}x${CROP_HEIGHT}."
		fi
		C=""
		[[ ${CROP_TOP} -ne 0 ]] && C="${C} -gravity North -chop 0x${CROP_TOP}"
		[[ ${CROP_RIGHT} -ne 0 ]] && C="${C} -gravity East -chop ${CROP_RIGHT}x0"
		[[ ${CROP_BOTTOM} -ne 0 ]] && C="${C} -gravity South -chop 0x${CROP_BOTTOM}"
		[[ ${CROP_LEFT} -ne 0 ]] && C="${C} -gravity West -chop ${CROP_LEFT}x0"

		# shellcheck disable=SC2086
		convert "${CURRENT_IMAGE}" ${C} "${CURRENT_IMAGE}"
		if [ $? -ne 0 ] ; then
			echo -e "${RED}*** ${ME}: ERROR: CROP_IMAGE failed; not saving${NC}"
			exit 4
		fi
	else
		echo -e "${RED}*** ${ME}: ERROR: Crop number(s) invalid; not cropping image.${NC}"
		display_error_and_exit "${ERROR_MSG}" "CROP"
	fi
fi

# Stretch the image if required, but only at night.
STRETCH_AMOUNT=0
STRETCH_MIDPOINT=0
if [[ ${DAY_OR_NIGHT} == "NIGHT" ]]; then
	STRETCH_AMOUNT="$( settings ".imagestretchamountnighttime" )"
	STRETCH_MIDPOINT="$( settings ".imagestretchmidpointnighttime" )"
else	# DAY
	STRETCH_AMOUNT="$( settings ".imagestretchamountdaytime" )"
	STRETCH_MIDPOINT="$( settings ".imagestretchmidpointdaytime" )"
fi
if [[ ${STRETCH_AMOUNT} -gt 0 ]]; then
	if [[ ${ALLSKY_DEBUG_LEVEL} -ge 3 ]]; then
		echo "*** ${ME}: Stretching '${CURRENT_IMAGE}' by ${STRETCH_AMOUNT}"
	fi
 	convert "${CURRENT_IMAGE}" -sigmoidal-contrast "${STRETCH_AMOUNT}x${STRETCH_MIDPOINT}%" "${IMAGE_TO_USE}"
	if [ $? -ne 0 ] ; then
		echo -e "${RED}*** ${ME}: ERROR: AUTO_STRETCH failed; not saving${NC}"
		exit 4
	fi
fi

if [ "${DAY_OR_NIGHT}" = "NIGHT" ] ; then
	# The 12 hours ago option ensures that we're always using today's date
	# even at high latitudes where civil twilight can start after midnight.
	export DATE_NAME="$( date -d '12 hours ago' +'%Y%m%d' )"
else
	# During the daytime we alway save the file in today's directory.
	export DATE_NAME="$( date +'%Y%m%d' )"
fi

"${ALLSKY_SCRIPTS}/flow-runner.py"

# The majority of the post-processing time for an image is in flow-runner.py.
# Since only one mini-timelapse can run at once and that code is embeded in this code
# in several places, remove our PID lock now.
rm -f "${PID_FILE}"

SAVED_FILE="${CURRENT_IMAGE}"						# The name of the file saved from the camera.
WEBSITE_FILE="${WORKING_DIR}/${FULL_FILENAME}"		# The name of the file the websites look for

TIMELAPSE_MINI_UPLOAD_VIDEO="$( settings ".minitimelapseupload" )"
# If needed, save the current image in today's directory.
if [[ $( settings ".savedaytimeimages" ) == "true" ||
	  $( settings ".savenighttimeimages" ) == "true" ]]; then
	SAVE_IMAGE="true"
else
	SAVE_IMAGE="false"
fi
if [[ ${SAVE_IMAGE} == "true" ]]; then
	# Determine what directory is the final resting place.
	if [[ ${DAY_OR_NIGHT} == "NIGHT" ]]; then
		# The 12 hours ago option ensures that we're always using today's date
		# even at high latitudes where civil twilight can start after midnight.
		DATE_NAME="$( date -d '12 hours ago' +'%Y%m%d' )"
	else
		# During the daytime we alway save the file in today's directory.
		DATE_NAME="$( date +'%Y%m%d' )"
	fi
	DATE_DIR="${ALLSKY_IMAGES}/${DATE_NAME}"
	mkdir -p "${DATE_DIR}"

	if [[ $( settings ".imagecreatethumbnails" ) == "true" ]]; then
		THUMBNAILS_DIR="${DATE_DIR}/thumbnails"
		mkdir -p "${THUMBNAILS_DIR}"
		# Create a thumbnail of the image for faster load in the WebUI.
		# If we resized above, this will be a resize of a resize,
		# but for thumbnails that should be ok.
		X="$( settings ".thumbnailsizex" )"
		Y="$( settings ".thumbnailsizey" )"
		if ! convert "${CURRENT_IMAGE}" -resize "${X}x${Y}" "${THUMBNAILS_DIR}/${IMAGE_NAME}" ; then
			echo -e "${YELLOW}*** ${ME}: WARNING: THUMBNAIL resize failed; continuing.${NC}"
		fi
	fi

	# The web server can't handle symbolic links so we need to make a copy of the file for
	# it to use.
	FINAL_FILE="${DATE_DIR}/${IMAGE_NAME}"
	if cp "${CURRENT_IMAGE}" "${FINAL_FILE}" ; then

		TIMELAPSE_MINI_IMAGES="$( settings ".minitimelapsenumimages" )"
		TIMELAPSE_MINI_FREQUENCY="$( settings ".minitimelapsefrequency" )"
		if [[ ${TIMELAPSE_MINI_IMAGES} -ne 0 && ${TIMELAPSE_MINI_FREQUENCY} -ne 1 ]]; then
			# We are creating mini-timelapses; see if we should create one now.

			MINI_TIMELAPSE_FILES="${ALLSKY_TMP}/mini-timelapse_files.txt"	 # List of files
			if [[ ! -f ${MINI_TIMELAPSE_FILES} ]]; then
				# The file may have been deleted for an unknown reason.
				echo "${FINAL_FILE}" > "${MINI_TIMELAPSE_FILES}"
				NUM_IMAGES=1
				LEFT=$((TIMELAPSE_MINI_IMAGES - NUM_IMAGES))
			else
				if ! grep --silent "${FINAL_FILE}" "${MINI_TIMELAPSE_FILES}" ; then
					echo "${FINAL_FILE}" >> "${MINI_TIMELAPSE_FILES}"
				elif [[ ${ALLSKY_DEBUG_LEVEL} -ge 1 ]]; then
					# This shouldn't happen...
					echo -e "${YELLOW}${ME} WARNING: '${FINAL_FILE}' already in set.${NC}" >&2
				fi
				NUM_IMAGES=$(wc -l < "${MINI_TIMELAPSE_FILES}")
				LEFT=$((TIMELAPSE_MINI_IMAGES - NUM_IMAGES))
			fi

			MOD=0
			TIMELAPSE_MINI_FORCE_CREATION="$( settings ".minitimelapseforcecreation" )"
			if [[ ${TIMELAPSE_MINI_FORCE_CREATION} == "true" ]]; then
				[[ ${ALLSKY_DEBUG_LEVEL} -ge 3 ]] && echo -e "NUM_IMAGES=${NUM_IMAGES}"

				# We only force creation every${TIMELAPSE_MINI_FREQUENCY} images,
				# and only when we haven't reached ${TIMELAPSE_MINI_IMAGES} or we're close.
				if [[ ${LEFT} -lt ${TIMELAPSE_MINI_FREQUENCY} ]]; then
					TIMELAPSE_MINI_FORCE_CREATION="false"
				else
					MOD="$(echo "${NUM_IMAGES} % ${TIMELAPSE_MINI_FREQUENCY}" | bc)"
					[[ ${MOD} -ne 0 ]] && TIMELAPSE_MINI_FORCE_CREATION="false"
				fi
			fi
			if [[ ${TIMELAPSE_MINI_FORCE_CREATION} == "true" || ${LEFT} -le 0 ]]; then
				# Create a mini-timelapse
				# This ALLSKY_DEBUG_LEVEL should be same as what's in upload.sh
				# This causes timelapse.sh to print "before" and "after" debug messages.
				if [[ ${ALLSKY_DEBUG_LEVEL} -ge 2 ]]; then
					D="--debug"
				else
					D="--no-debug"
				fi
				O="${ALLSKY_TMP}/mini-timelapse.mp4"
				"${ALLSKY_SCRIPTS}/timelapse.sh" "${D}" --lock --output "${O}" \
					--mini --images "${MINI_TIMELAPSE_FILES}"
				if [[ $? -ne 0 ]]; then
					# failed so don't try to upload
					TIMELAPSE_MINI_UPLOAD_VIDEO="false"
					# This leaves the lock file since it belongs to another running process.
					ALLSKY_TIMELAPSE_PID_FILE=""
				fi

				# Remove the oldest files, but not if we only created
				# this mini-timelapse because of a force.
				if [[ ${RET} -eq 0 && (${MOD} -ne 0 || ${TIMELAPSE_MINI_FORCE_CREATION} == "false") ]]; then
					KEEP=$((TIMELAPSE_MINI_IMAGES - TIMELAPSE_MINI_FREQUENCY))
					x="$( tail -${KEEP} "${MINI_TIMELAPSE_FILES}" )"
					echo -e "${x}" > "${MINI_TIMELAPSE_FILES}"
					if [[ ${ALLSKY_DEBUG_LEVEL} -ge 3 ]]; then
						echo -en "${YELLOW}${ME}: Replaced ${TIMELAPSE_MINI_FREQUENCY} oldest"
						echo -e " timelapse file(s).${NC}" >&2
					fi
				fi
			else
				# Not ready to create yet
				if [[ ${ALLSKY_DEBUG_LEVEL} -ge 3 ]]; then
					echo -n "NUM_IMAGES=${NUM_IMAGES}: Not creating mini timelapse: "
					if [[ ${MOD} -eq 0 ]]; then
						echo "${LEFT} images(s) left."
					else
						echo "$((TIMELAPSE_MINI_FREQUENCY - MOD)) images(s) left in frequency."
					fi
				fi
				TIMELAPSE_MINI_UPLOAD_VIDEO="false"
			fi
		fi

	else
		echo "*** ERROR: ${ME}: unable to copy ${CURRENT_IMAGE} ***"
		SAVE_IMAGE="false"
		TIMELAPSE_MINI_UPLOAD_VIDEO="false"			# so we can easily compare below
	fi
fi

if [[ ${TIMELAPSE_MINI_UPLOAD_VIDEO} == "false" ]]; then
	ALLSKY_TIMELAPSE_PID_FILE=""			# so we don't try to remove the non-existant file
fi

# If upload is true, optionally create a smaller version of the image; either way, upload it
RET=0
IMG_UPLOAD_FREQUENCY="$( settings ".imageuploadfrequency" )"
if [[ ${IMG_UPLOAD_FREQUENCY} -gt 0 ]]; then
	# First check if we should upload this image
	if [[ ${IMG_UPLOAD_FREQUENCY} -ne 1 ]]; then
		FREQUENCY_FILE="${ALLSKY_TMP}/IMG_UPLOAD_FREQUENCY.txt"
		if [[ ! -f ${FREQUENCY_FILE} ]]; then
			# The file may have been deleted, or the user may have just changed the frequency.
			LEFT=${IMG_UPLOAD_FREQUENCY}
		else
			LEFT=$( < "${FREQUENCY_FILE}" )
		fi
		if [[ ${LEFT} -le 1 ]]; then
			# upload this one and reset the counter
			echo "${IMG_UPLOAD_FREQUENCY}" > "${FREQUENCY_FILE}"
		else
			# Not ready to upload yet, so decrement the counter
			LEFT=$((LEFT - 1))
			echo "${LEFT}" > "${FREQUENCY_FILE}"
			# This ALLSKY_DEBUG_LEVEL should be same as what's in upload.sh
			[[ ${ALLSKY_DEBUG_LEVEL} -ge 3 ]] && echo "${ME}: Not uploading image: ${LEFT} images(s) left."

			# We didn't create ${WEBSITE_FILE} yet so do that now.
			mv "${CURRENT_IMAGE}" "${WEBSITE_FILE}"

			exit 0
		fi
	fi

	W="$( settings ".imageresizeuploadswidth" )"
	H="$( settings ".imageresizeuploadsheight" )"
	if [[ ${W} -gt 0 && ${H} -gt 0 ]]; then
		RESIZE_UPLOADS="true"
	else
		RESIZE_UPLOADS="false"
	fi
	if [[ ${RESIZE_UPLOADS} == "true" ]]; then
		# Need a copy of the image since we are going to resize it.
		# Put the copy in ${WORKING_DIR}.
		FILE_TO_UPLOAD="${WORKING_DIR}/resize-${IMAGE_NAME}"
		S="${W}x${H}"
		[ "${ALLSKY_DEBUG_LEVEL}" -ge 3 ] && echo "*** ${ME}: Resizing upload file '${FILE_TO_UPLOAD}' to ${S}"
		if ! convert "${CURRENT_IMAGE}" -resize "${S}" -gravity East -chop 2x0 "${FILE_TO_UPLOAD}" ; then
			echo -e "${YELLOW}*** ${ME}: WARNING: Resize Uploads failed; continuing with larger image.${NC}"
			# We don't know the state of $FILE_TO_UPLOAD so use the larger file.
			FILE_TO_UPLOAD="${CURRENT_IMAGE}"
		fi
	else
		FILE_TO_UPLOAD="${CURRENT_IMAGE}"
	fi

	if [[ $( settings ".imageuploadoriginalname" ) == "true" ]]; then
		DESTINATION_NAME=""
	else
		DESTINATION_NAME="${FULL_FILENAME}"
	fi

	# Goes in root of Website so second arg is "".
	upload_all --remote-web --remote-server "${FILE_TO_UPLOAD}" "" "${DESTINATION_NAME}" "SaveImage"
	RET=$?

	[[ ${RESIZE_UPLOADS} == "true" ]] && rm -f "${FILE_TO_UPLOAD}"	# was a temporary file
fi

# If needed, upload the mini timelapse.  If the upload failed above, it will likely fail below.
if [[ ${TIMELAPSE_MINI_UPLOAD_VIDEO} == "true" && ${SAVE_IMAGE} == "true" && ${RET} -eq 0 ]] ; then
	MINI="mini-timelapse.mp4"
	FILE_TO_UPLOAD="${ALLSKY_TMP}/${MINI}"

	upload_all --remote-web --remote-server "${FILE_TO_UPLOAD}" "" "${MINI}" "MiniTimelapse"
	RET=$?
	if [[ ${RET} -eq 0 && $( settings ".minitimelapseuploadthumbnail" ) == "true" ]]; then
		UPLOAD_THUMBNAIL_NAME="mini-timelapse.jpg"
		UPLOAD_THUMBNAIL="${ALLSKY_TMP}/${UPLOAD_THUMBNAIL_NAME}"
		# Create the thumbnail for the mini timelapse, then upload it.
		rm -f "${UPLOAD_THUMBNAIL}"
		make_thumbnail "00" "${FILE_TO_UPLOAD}" "${UPLOAD_THUMBNAIL}"
		if [[ ! -f ${UPLOAD_THUMBNAIL} ]]; then
			echo "${ME}: Mini timelapse thumbnail not created!"
		else
			# Use --silent because we just displayed message(s) above for this image.
			upload_all --remote-web --remote-server --silent \
				"${UPLOAD_THUMBNAIL}" \
				"" \
				"${UPLOAD_THUMBNAIL_NAME}" \
				"MiniThumbnail"
		fi
	fi
fi

# We're done with the mini-timelapse so remove the lock file.
[[ -n ${ALLSKY_TIMELAPSE_PID_FILE} ]] && rm -f "${ALLSKY_TIMELAPSE_PID_FILE}"

# We create ${WEBSITE_FILE} as late as possible to avoid it being overwritten.
mv "${SAVED_FILE}" "${WEBSITE_FILE}"

exit 0
