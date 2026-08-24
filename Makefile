all:
	rsrc -manifest win-classic-volume-tray.exe.manifest -ico icon_32x32.ico
	GOOS=windows go build -ldflags="-H windowsgui" .
