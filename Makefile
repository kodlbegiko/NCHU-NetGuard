.PHONY: all build install test clean
APP := build/NCHUTraffic.app
INSTALL_DIR ?= $(HOME)/Applications

all: build

build:
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	swiftc -O src/main.swift src/QuickPanel.swift src/HistoryAnalyticsView.swift src/SettingsView.swift src/ManagementView.swift src/AutomationView.swift Sources/NetGuardCore/*.swift Sources/NetGuardObservation/*.swift Sources/NetGuardWorkflow/*.swift Sources/NetGuardRecovery/*.swift Sources/NetGuardProvider/*.swift Sources/NetGuardTraffic/*.swift Sources/NetGuardData/*.swift -lsqlite3 -o "$(APP)/Contents/MacOS/NCHUTraffic"
	cp src/Info.plist "$(APP)/Contents/"
	cp src/Resources/popover.html scripts/traffic_monitor.py "$(APP)/Contents/Resources/"

install: build
	mkdir -p "$(INSTALL_DIR)"
	ditto "$(APP)" "$(INSTALL_DIR)/NCHUTraffic.app"

test:
	python3 -m unittest discover -s tests -p 'test_*.py' -v

clean:
	rm -rf build
