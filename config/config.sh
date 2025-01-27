#!/bin/bash

# X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*XX*X*X*X*X*X*X

# For details on these settings, click on the "Allsky Documentation" link in the WebUI,
# then click on the "Settings -> Allsky" link,
# then, in the "Editor WebUI Page" section, open the "config.sh" sub-section.

# X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*X*XX*X*X*X*X*X*X


########## Images
# Set to "true" to upload the current image to your website.
IMG_UPLOAD="false"

# Upload the image file as "image-YYYYMMDDHHMMSS.jpg" (true) or "image.jpg" (false).
IMG_UPLOAD_ORIGINAL_NAME="false"

# If IMG_UPLOAD is "true", upload images every IMG_UPLOAD_FREQUENCY frames, e.g., every 5 frames.
# 1 uploades every frame.
IMG_UPLOAD_FREQUENCY=1

# Resize images before cropping, stretching, and saving.
IMG_RESIZE="false"
IMG_WIDTH=2028
IMG_HEIGHT=1520

# Crop images before stretching and saving.
CROP_IMAGE="false"
CROP_WIDTH=640
CROP_HEIGHT=480
CROP_OFFSET_X=0
CROP_OFFSET_Y=0

# Auto stretch images saved at night.  The numbers below are good defaults.
AUTO_STRETCH="false"
AUTO_STRETCH_AMOUNT=10
AUTO_STRETCH_MID_POINT="10%"

# Resize uploaded images.  Change the size to fit your sensor.  
RESIZE_UPLOADS="false"
RESIZE_UPLOADS_WIDTH=962
RESIZE_UPLOADS_HEIGHT=720

# Create thumbnails of images.  If you never look at them, consider changing this to "false".
IMG_CREATE_THUMBNAILS="false"

# Remove corrupt or too dim/bright images.
REMOVE_BAD_IMAGES="true"
REMOVE_BAD_IMAGES_THRESHOLD_LOW=1
REMOVE_BAD_IMAGES_THRESHOLD_HIGH=90


########## Timelapse
# Set to "true" to generate a timelapse video at the end of each night.
TIMELAPSE="true"

# Set the resolution in pixels of the timelapse video.
TIMELAPSEWIDTH=2028
TIMELAPSEHEIGHT=1520

# Bitrate of the timelapse video.
TIMELAPSE_BITRATE="2000k"

# Timelapse video Frames Per Second.
FPS=25

# Encoder for timelapse video.
VCODEC="libx264"

# Pixel format.
PIX_FMT="yuv420p"

# Amount of information displayed while creating a timelapse video.
FFLOG="warning"

# Set to "true" to keep the list of files used in creating the timelapse video.
KEEP_SEQUENCE="false"

# Any additional timelapse parameters.  Run "ffmpeg -?" to see the options.
TIMELAPSE_EXTRA_PARAMETERS=""

# Set to "true" to upload the timelapse video to your website at the end of each night.
UPLOAD_VIDEO="false"

# Set to "true" to upload the timelapse video's thumbnail to your website at the end of each night.
TIMELAPSE_UPLOAD_THUMBNAIL="true"

###### Mini-timelapse
# The number of images you want in the mini-timelapse.  0 disables mini-timelapse creation.
TIMELAPSE_MINI_IMAGES=0

# Should a mini-timelapse be created even if ${TIMELAPSE_MINI_IMAGES} haven't been captured yet?
TIMELAPSE_MINI_FORCE_CREATION="false"

# After how many images should the mini-timelapse be made?
# If you have a slow Pi or short delays between images,
# set this to a higher number (i.e., not as often).
TIMELAPSE_MINI_FREQUENCY=5

# The remaining TIMELAPSE_MINI_* variables serve the same function as the daily timelapse.
TIMELAPSE_MINI_UPLOAD_VIDEO="true"
TIMELAPSE_MINI_UPLOAD_THUMBNAIL="true"
TIMELAPSE_MINI_FPS=5
TIMELAPSE_MINI_BITRATE="1000k"
TIMELAPSE_MINI_WIDTH=1014
TIMELAPSE_MINI_HEIGHT=760


########## Keogram
# Set to "true" to generate a keogram at the end of each night.
KEOGRAM="true"

# Additional Keogram parameters.
KEOGRAM_EXTRA_PARAMETERS="--font-size 1.0 --font-line 1 --font-color '255 255 255'"

# Set to "true" to upload the keogram image to your website at the end of each night.
UPLOAD_KEOGRAM="false"


########## Startrails
# Set to "true" to generate a startrails image of each night.
STARTRAILS="true"

# Images with a brightness higher than this threshold will be skipped for
# startrails image generation.
BRIGHTNESS_THRESHOLD=0.15

# Any additional startrails parameters.
STARTRAILS_EXTRA_PARAMETERS=""

# Set to "true" to upload the startrails image to your website at the end of each night.
UPLOAD_STARTRAILS="false"


########## Other
# Size of thumbnails.
THUMBNAIL_SIZE_X=100
THUMBNAIL_SIZE_Y=75

# Set this value to the number of days images plus videos you want to keep.
# Set to 0 to keep ALL days.
DAYS_TO_KEEP=7

# Same as DAYS_TO_KEEP, but for the Allsky Website, if installed.
WEB_DAYS_TO_KEEP=0

# See the documentation for a description of this setting.
WEBUI_DATA_FILES=""

# See the documentation for a description of these settings.
UHUBCTL_PATH=""
UHUBCTL_PORT=2


# ================ DO NOT CHANGE ANYTHING BELOW THIS LINE ================
ME2="$(basename "${BASH_SOURCE[0]}")"

# CAMERA_TYPE is updated during installation
CAMERA_TYPE="RPi"
if [ "${CAMERA_TYPE}" = "" ]; then
	echo -e "${RED}${ME2}: ERROR: Please set 'Camera Type' in the WebUI.${NC}"
	sudo systemctl stop allsky > /dev/null 2>&1
	exit ${EXIT_ERROR_STOP}
fi

IMG_DIR="current/tmp"
CAPTURE_SAVE_DIR="${ALLSKY_TMP}"

# Don't try to upload a mini-timelapse if they aren't using them.
if [[ ${TIMELAPSE_MINI_IMAGES} -eq 0 ]]; then
	TIMELAPSE_MINI_UPLOAD_VIDEO="false"
	TIMELAPSE_MINI_UPLOAD_THUMBNAIL="false"
fi

if [[ -z ${SETTINGS_FILE} ]]; then		# SETTINGS_FILE is defined in variables.sh
	echo -e "${RED}${ME2}: ERROR: SETTINGS_FILE variable not defined!${NC}"
	echo -e "${RED}Make sure 'variables.sh' is source'd in!${NC}"
	return 1
fi
if [[ ! -f ${SETTINGS_FILE} ]]; then
	echo -e "${RED}${ME2}: ERROR: Settings file '${SETTINGS_FILE}' not found!${NC}"
	sudo systemctl stop allsky > /dev/null 2>&1
	exit ${EXIT_ERROR_STOP}
fi

# Get the name of the file the websites will look for, and split into name and extension.
FULL_FILENAME="$(settings ".filename")"
EXTENSION="${FULL_FILENAME##*.}"
FILENAME="${FULL_FILENAME%.*}"
 
CAMERA_MODEL="$(settings '.cameraModel')"

# So scripts can conditionally output messages.
ALLSKY_DEBUG_LEVEL="$(settings '.debuglevel')"
# ALLSKY_VERSION is updated during installation
ALLSKY_VERSION="v2023.05.01_03"

CONFIG_SH_VERSION=1
