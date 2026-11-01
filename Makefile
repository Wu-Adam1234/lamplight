VERSION := $(shell cat VERSION)

.PHONY: build test app install icons demo run windows clean

build:
	swift build

test:
	swift test

run: build
	swift run Lamplight

icons:
	swift scripts/render-icon.swift build/icons

demo: build
	.build/debug/Lamplight --render-demo docs/assets/demo.gif

app:
	scripts/build-app.sh $(VERSION)

install: app
	@if pgrep -x Lamplight >/dev/null; then osascript -e 'quit app "Lamplight"'; sleep 1; fi
	rm -rf /Applications/Lamplight.app
	ditto dist/Lamplight.app /Applications/Lamplight.app
	open /Applications/Lamplight.app

windows:
	scripts/build-windows.sh $(VERSION)

clean:
	rm -rf .build build dist
