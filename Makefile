BINARY := .build/release/pixelwatch
BUNDLE := PixelWatch.app

.PHONY: build bundle run clean

build:
	swift build -c release

bundle: build
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp $(BINARY) $(BUNDLE)/Contents/MacOS/pixelwatch
	cp Sources/pixelwatch/Info.plist $(BUNDLE)/Contents/Info.plist
	touch $(BUNDLE)
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u $(BUNDLE) 2>/dev/null; true
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister $(BUNDLE)
	@echo "Bundle created and registered. Run with: open $(BUNDLE)"

run: bundle
	open $(BUNDLE)

clean:
	rm -rf .build $(BUNDLE)
