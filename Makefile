build:
	mkdir -p build/NCHUTraffic.app/Contents/MacOS
	mkdir -p build/NCHUTraffic.app/Contents/Resources
	swiftc -O src/main.swift -o build/NCHUTraffic.app/Contents/MacOS/NCHUTraffic
	cp src/Info.plist build/NCHUTraffic.app/Contents/
	cp src/Resources/popover.html build/NCHUTraffic.app/Contents/Resources/

clean:
	rm -rf build
