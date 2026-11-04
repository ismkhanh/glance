# A screenshot of the whole screen (points, not pixels, are what the driver uses: half the pixel size on Retina).
cd "${0:A:h}/../.."
screencapture -x -C demo/logs/screen.png && sips -g pixelWidth -g pixelHeight demo/logs/screen.png
