all:
	zig build -Doptimize=ReleaseSmall
	cp zig-out/bin/win-classic-volume-tray.exe .

clean:
	rm -rf zig-out .zig-cache win-classic-volume-tray.exe win-classic-volume-tray.pdb

.PHONY: all clean
